import Foundation

public enum ADBHardwareFetcher {
    private static let A_CNXN: UInt32 = 0x4e584e43
    private static let A_OPEN: UInt32 = 0x4e45504f
    private static let A_OKAY: UInt32 = 0x59414b4f
    private static let A_CLSE: UInt32 = 0x45534c43
    private static let A_WRTE: UInt32 = 0x45545257

    private static func makePacket(command: UInt32, arg0: UInt32, arg1: UInt32, data: Data = Data()) -> Data {
        var pkt = Data()
        var check: UInt32 = 0
        for byte in data { check &+= UInt32(byte) }
        let magic = command ^ 0xffffffff

        var c = command.littleEndian; pkt.append(Data(bytes: &c, count: 4))
        var a0 = arg0.littleEndian; pkt.append(Data(bytes: &a0, count: 4))
        var a1 = arg1.littleEndian; pkt.append(Data(bytes: &a1, count: 4))
        var dl = UInt32(data.count).littleEndian; pkt.append(Data(bytes: &dl, count: 4))
        var chk = check.littleEndian; pkt.append(Data(bytes: &chk, count: 4))
        var m = magic.littleEndian; pkt.append(Data(bytes: &m, count: 4))
        pkt.append(data)
        return pkt
    }

    private static func readExact(from sock: Int32, count: Int) -> Data? {
        var result = Data(count: count)
        var total = 0
        while total < count {
            let readBytes = result.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return recv(sock, base.advanced(by: total), count - total, 0)
            }
            if readBytes <= 0 { return nil }
            total += readBytes
        }
        return result
    }

    /// 通过 ADB 5555 端口原生 Socket 发送 shell 命令并获取输出（纯 Swift 实现，跨平台零外部依赖）
    public static func executeShell(
        host: String,
        port: UInt16 = 5555,
        command: String,
        timeoutSec: Double = 3.0
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM

            var servinfo: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &servinfo) == 0, let info = servinfo else {
                return nil
            }
            defer { freeaddrinfo(servinfo) }

            let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard sock >= 0 else { return nil }
            defer { close(sock) }

            var tv = timeval(
                tv_sec: Int(timeoutSec),
                tv_usec: Int32((timeoutSec.truncatingRemainder(dividingBy: 1.0)) * 1_000_000)
            )
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            guard connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
                return nil
            }

            // 1. 发送 CNXN 握手
            let hostData = "host::\0".data(using: .utf8)!
            let cnxnPacket = makePacket(command: A_CNXN, arg0: 0x01000000, arg1: 0x00100000, data: hostData)
            _ = cnxnPacket.withUnsafeBytes { ptr in send(sock, ptr.baseAddress!, ptr.count, 0) }

            // 2. 读取 CNXN 应答
            guard let cnxnHdr = readExact(from: sock, count: 24) else { return nil }
            let resCmd = cnxnHdr.withUnsafeBytes { ptr in ptr.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let resDataLen = Int(cnxnHdr.withUnsafeBytes { ptr in ptr.load(fromByteOffset: 12, as: UInt32.self).littleEndian })
            if resDataLen > 0 { _ = readExact(from: sock, count: resDataLen) }
            guard resCmd == A_CNXN else { return nil }

            // 3. 发送 OPEN shell 命令
            let shellPayload = "shell:\(command)\0".data(using: .utf8)!
            let localId: UInt32 = 1
            let openPacket = makePacket(command: A_OPEN, arg0: localId, arg1: 0, data: shellPayload)
            _ = openPacket.withUnsafeBytes { ptr in send(sock, ptr.baseAddress!, ptr.count, 0) }

            var outputData = Data()
            while true {
                // 超时或半包都属于失败，不能把末尾缺失的输出当作完整结果。
                guard let hdr = readExact(from: sock, count: 24) else { return nil }
                let pCmd = hdr.withUnsafeBytes { ptr in ptr.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                let pArg0 = hdr.withUnsafeBytes { ptr in ptr.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
                let pLen = Int(hdr.withUnsafeBytes { ptr in ptr.load(fromByteOffset: 12, as: UInt32.self).littleEndian })

                var body = Data()
                if pLen > 0 {
                    guard let b = readExact(from: sock, count: pLen) else { return nil }
                    body = b
                }

                if pCmd == A_WRTE {
                    outputData.append(body)
                    let okayPkt = makePacket(command: A_OKAY, arg0: localId, arg1: pArg0)
                    _ = okayPkt.withUnsafeBytes { ptr in send(sock, ptr.baseAddress!, ptr.count, 0) }
                } else if pCmd == A_CLSE {
                    let closePacket = makePacket(command: A_CLSE, arg0: localId, arg1: pArg0)
                    _ = closePacket.withUnsafeBytes { ptr in send(sock, ptr.baseAddress!, ptr.count, 0) }
                    break
                }
            }
            return String(data: outputData, encoding: .utf8)
        }.value
    }

}
