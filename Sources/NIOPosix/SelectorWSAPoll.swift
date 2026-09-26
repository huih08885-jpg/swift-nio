//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !os(WASI)

#if os(Windows)
import CNIOWindows
import NIOConcurrencyHelpers
import NIOCore
import WinSDK

extension SelectorEventSet {
    // Use this property to create pollfd's event field. Reset and errors are (hopefully) always included.
    // According to the docs we don't need to listen for them explicitly.
    // Source: https://learn.microsoft.com/en-us/windows/win32/api/winsock2/ns-winsock2-wsapollfd
    var wsaPollEvent: Int16 {
        var result: Int16 = 0
        if self.contains(.read) {
            result |= Int16(WinSDK.POLLRDNORM)
        }
        if self.contains(.write) || self.contains(.writeEOF) {
            result |= Int16(WinSDK.POLLWRNORM)
        }
        return result
    }

    // Use this initializer to create a EventSet from the wsa pollfd's revent field
    @usableFromInline
    init(revents: Int16) {
        // Event Constant   Meaning	                What to do (Typical Socket API)
        // POLLRDNORM       Normal data readable    Use recv, WSARecv, or ReadFile
        // POLLRDBAND       Priority data readable  Use recv, WSARecv (with MSG_OOB for out-of-band)
        // POLLWRNORM       Normal data writable    Use send, WSASend, or WriteFile
        // POLLWRBAND       Priority data writable  Use send (with MSG_OOB for out-of-band data)
        // POLLERR          Error condition         Use getsockopt with SO_ERROR; may need closesocket
        // POLLHUP          Closed                  Usually just cleanup: closesocket
        // POLLNVAL         Invalid fd (not open)   Fix your code; close and remove fd
        self.rawValue = 0
        let mapped = Int32(revents)
        if mapped & WinSDK.POLLRDNORM != 0 {
            self.formUnion(.read)
        }
        if mapped & WinSDK.POLLWRNORM != 0 {
            self.formUnion(.write)
        }
        if mapped & WinSDK.POLLERR != 0 {
            self.formUnion(.error)
        }
        if mapped & WinSDK.POLLHUP != 0 {
            self.formUnion(.reset)
        }
        if mapped & WinSDK.POLLNVAL != 0 {
            preconditionFailure("Invalid fd supplied.")
        }
    }
}

extension Selector: _SelectorBackendProtocol {

    func initialiseState0() throws {
        self.pollFDs.reserveCapacity(16)
        self.deregisteredFDs.reserveCapacity(16)

        // Wake-up mechanism.
        //
        // On Linux we use eventfd and on Darwin we use a kevent-only EVFILT_USER.
        // Windows has no direct equivalent. The natural-looking choice would be
        // QueueUserAPC against the event-loop thread, but APCs only fire while
        // the target thread is in an alertable wait. WSAPoll is not alertable —
        // there is no `WSAPollEx`/`SleepEx`-style waitable variant that both
        // observes the registered sockets *and* picks up APCs in one call. That
        // would force us to either spin or split the wait into two phases, both
        // of which are unacceptable from a correctness/latency perspective.
        //
        // Instead, we mirror the eventfd pattern: create a connected socket pair
        // ourselves and include the read end as the first entry in `pollFDs`.
        // `wakeup0` writes a byte to the write end; the next WSAPoll returns and
        // the read end gets drained at the top of `whenReady0`. Windows package
        // identities reject AF_UNIX bind with WSAEINVAL, so use a TCP pair whose
        // listener is restricted to loopback and closed before returning.
        let (readSocket, writeSocket) = try Self.createWakeupSocketPair()
        self.wakeupReadSocket = readSocket
        self.wakeupWriteSocket = writeSocket

        // The read end of the wakeup pair is always the first entry in pollFDs;
        // `whenReady0` relies on this invariant to drain wakeup bytes cheaply.
        // We deliberately do *not* publish the wakeup socket in `pollFDIndexes`
        // — user-facing register/reregister/deregister operations should never
        // see or touch the wakeup slot.
        let wakeupPollFD = pollfd(fd: UInt64(readSocket), events: Int16(WinSDK.POLLRDNORM), revents: 0)
        self.pollFDs.append(wakeupPollFD)

        self.lifecycleState = .open
    }

    /// Creates a pair of connected loopback TCP sockets for wakeup signaling.
    /// Since Windows doesn't support socketpair(), we emulate it with listen/connect/accept.
    /// Returns (readSocket, writeSocket) tuple.
    private static func createWakeupSocketPair() throws -> (NIOBSDSocket.Handle, NIOBSDSocket.Handle) {
        let listenerSocket = try NIOBSDSocket.socket(domain: .inet, type: .stream, protocolSubtype: .default)
        defer {
            _ = try? NIOBSDSocket.close(socket: listenerSocket)
        }

        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = WinSDK.htonl(UInt32(bitPattern: INADDR_LOOPBACK))
        address.sin_port = 0
        let addressLength = socklen_t(MemoryLayout.size(ofValue: address))
        try withUnsafePointer(to: &address) { addressPointer in
            try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try NIOBSDSocket.bind(
                    socket: listenerSocket,
                    address: socketPointer,
                    address_len: addressLength
                )
            }
        }
        if WinSDK.listen(listenerSocket, 1) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "listen")
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = addressLength
        try withUnsafeMutablePointer(to: &boundAddress) { addressPointer in
            try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try NIOBSDSocket.getsockname(
                    socket: listenerSocket,
                    address: socketPointer,
                    address_len: &boundAddressLength
                )
            }
        }

        let writeSocket = try NIOBSDSocket.socket(domain: .inet, type: .stream, protocolSubtype: .default)
        do {
            try withUnsafePointer(to: &boundAddress) { addressPointer in
                try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    guard
                        try NIOBSDSocket.connect(
                            socket: writeSocket,
                            address: socketPointer,
                            address_len: boundAddressLength
                        )
                    else {
                        throw IOError(winsock: WSAGetLastError(), reason: "connect")
                    }
                }
            }
            let readSocket = WinSDK.accept(listenerSocket, nil, nil)
            if readSocket == INVALID_SOCKET {
                throw IOError(winsock: WSAGetLastError(), reason: "accept")
            }

            return (readSocket, writeSocket)
        } catch {
            _ = try? NIOBSDSocket.close(socket: writeSocket)
            throw error
        }
    }

    func deinitAssertions0() {
        assert(
            self.wakeupReadSocket == NIOBSDSocket.invalidHandle,
            "wakeupReadSocket == \(self.wakeupReadSocket) in deinitAssertions0, forgot close?"
        )
        assert(
            self.wakeupWriteSocket == NIOBSDSocket.invalidHandle,
            "wakeupWriteSocket == \(self.wakeupWriteSocket) in deinitAssertions0, forgot close?"
        )
    }

    @inlinable
    func whenReady0(
        strategy: SelectorStrategy,
        onLoopBegin: () -> Void,
        _ body: (SelectorEvent<R>) throws -> Void
    ) throws {
        let time: Int32 =
            switch strategy {
            case .now:
                0

            case .block:
                -1

            case .blockUntilTimeout(let timeAmount):
                Int32(clamping: timeAmount.nanoseconds / 1_000_000)
            }

        precondition(
            !self.pollFDs.isEmpty,
            "pollFDs should never be empty here, since we need an eventFD for waking up on demand"
        )
        // We always have at least the wakeup socket in pollFDs
        let result = self.pollFDs.withUnsafeMutableBufferPointer { ptr in
            WSAPoll(ptr.baseAddress!, UInt32(ptr.count), time)
        }

        if result > 0 {
            // something has happened
            for i in self.pollFDs.indices {
                let pollFD = self.pollFDs[i]
                guard pollFD.revents != 0 else {
                    continue
                }
                // reset the revents
                self.pollFDs[i].revents = 0
                let fd = pollFD.fd

                // Check if this is the wakeup socket
                if NIOBSDSocket.Handle(fd) == self.wakeupReadSocket {
                    // Drain the wakeup socket by reading the data that was sent
                    var buffer: UInt8 = 0
                    _ = withUnsafeMutablePointer(to: &buffer) { ptr in
                        WinSDK.recv(self.wakeupReadSocket, ptr, 1, 0)
                    }
                    continue
                }

                // If the registration is not in the Map anymore we deregistered it during the processing of whenReady(...). In this case just skip it.
                guard let registration = self.registrations[Int(fd)] else {
                    continue
                }

                var selectorEvent = SelectorEventSet(revents: pollFD.revents)
                // in any case we only want what the user is currently registered for & what we got
                selectorEvent = selectorEvent.intersection(registration.interested)

                guard selectorEvent != ._none else {
                    continue
                }

                try body((SelectorEvent(io: selectorEvent, registration: registration)))
            }

            // Clean up any deregistered fds in a single linear in-place compaction
            // pass: walk `pollFDs` once with a read/write cursor, dropping entries
            // whose index is in `deregisteredFDs` and updating `pollFDIndexes`
            // for any surviving entry that shifted left. This is O(n) and avoids
            // both the previous `sorted(by: >)` (O(k log k)) and per-call
            // `pollFDs.remove(at:)` (O(n) each, O(k·n) total).
            //
            // The wakeup socket is always at `pollFDs[0]` and is never registered
            // in `pollFDIndexes`, so we treat index 0 as a fixed survivor.
            if !self.deregisteredFDs.isEmpty {
                var write = 0
                for read in 0..<self.pollFDs.count {
                    if self.deregisteredFDs.contains(read) {
                        let fd = self.pollFDs[read].fd
                        self.registrations.removeValue(forKey: Int(fd))
                        continue
                    }
                    if write != read {
                        self.pollFDs[write] = self.pollFDs[read]
                        if write != 0 {
                            self.pollFDIndexes[NIOBSDSocket.Handle(self.pollFDs[write].fd)] = write
                        }
                    }
                    write += 1
                }
                self.pollFDs.removeLast(self.pollFDs.count - write)
                self.deregisteredFDs.removeAll(keepingCapacity: true)
            }
        } else if result == 0 {
            // nothing has happened
        } else if result == WinSDK.SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "WSAPoll")
        }
    }

    func register0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        interested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        let poll = pollfd(fd: UInt64(fileDescriptor), events: interested.wsaPollEvent, revents: 0)
        self.pollFDIndexes[fileDescriptor] = self.pollFDs.count
        self.pollFDs.append(poll)
    }

    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDIndexes[fileDescriptor] {
            self.pollFDs[index].events = newInterested.wsaPollEvent
        }
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDIndexes.removeValue(forKey: fileDescriptor) {
            self.deregisteredFDs.insert(index)
        }
    }

    func wakeup0() throws {
        // Will be called from a different thread.
        // Write a single byte to the wakeup socket to wake up the event loop.
        try self.externalSelectorFDLock.withLock {
            guard self.wakeupWriteSocket != NIOBSDSocket.invalidHandle else {
                throw EventLoopError.shutdown
            }
            var byte: UInt8 = 0
            let result = withUnsafePointer(to: &byte) { ptr in
                WinSDK.send(self.wakeupWriteSocket, ptr, 1, 0)
            }
            if result == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "send (wakeup)")
            }
        }
    }

    func close0() throws {
        // Like the epoll and kqueue selectors, serialize mutation of the wakeup
        // sockets against `wakeup0` (which may run on another thread) by taking
        // `externalSelectorFDLock`.
        self.externalSelectorFDLock.withLock {
            // Close the wakeup sockets
            if self.wakeupReadSocket != NIOBSDSocket.invalidHandle {
                try? NIOBSDSocket.close(socket: self.wakeupReadSocket)
                self.wakeupReadSocket = NIOBSDSocket.invalidHandle
            }
            if self.wakeupWriteSocket != NIOBSDSocket.invalidHandle {
                try? NIOBSDSocket.close(socket: self.wakeupWriteSocket)
                self.wakeupWriteSocket = NIOBSDSocket.invalidHandle
            }
            self.pollFDs.removeAll()
            self.pollFDIndexes.removeAll()
            self.deregisteredFDs.removeAll()
        }
    }
}
#endif
#endif  // !os(WASI)
