# Owned SwiftNIO fork notes

This tree is **apple/swift-nio 2.101.3** (`0b18836`) plus one Windows-only change:

- File: `Sources/NIOPosix/SelectorWSAPoll.swift`
- Change: wakeup pair uses loopback TCP instead of AF_UNIX
- Why: packaged Windows app identities reject AF_UNIX bind (`WSAEINVAL`), which can leave the event loop unable to wake for clean shutdown

ai-bridge / BridgeCore depends on this directory via a **path** package entry (not a third-party GitHub URL).

Optional remote mirror for the same content: https://github.com/huih08885-jpg/swift-nio  
Use `Scripts/push-owned-swift-nio.ps1` from this monorepo to publish the prepared tree when GitHub git access is available.

Drop this vendor and switch back to `apple/swift-nio` once upstream ships an equivalent fix.
