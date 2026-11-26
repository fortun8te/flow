import Accelerate
import Foundation

/// tinynext v2 (huggingface.co/paperweight/tinynext, MIT): a 12.5M-parameter causal language model,
/// run natively with Accelerate. Flow uses it only as a context scorer: given a few spellings of the
/// same spot ("odenst" -> doesn't / dense / does), it says which reads most like real text in context.
/// The same trick offlinepage.app uses next to tinyfix. Weights are int8 per row (tinynext-v2.q8,
/// converted from the published safetensors; scores match float within about 1%).
final class TinyNextScorer: @unchecked Sendable {
    static let shared = TinyNextScorer()

    private let lock = NSLock()
    private var model: Model?
    private var loading = false
    private var retryAfter: ContinuousClock.Instant?

    /// Loads the weights once, off the calling thread. Safe to call many times.
    func prewarm() {
        lock.lock()
        let start = model == nil && !loading && (retryAfter.map { $0 <= .now } ?? true)
        if start { loading = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { self.load() }
    }

    private func load() {
        let loaded = Self.resourceDirectory().flatMap { Model(directory: $0) }
        lock.lock()
        model = loaded
        retryAfter = loaded == nil ? .now + .seconds(30) : nil
        loading = false
        lock.unlock()
    }

    /// The model, loading it synchronously when `wait` is set (tests, the CLI). Nil while loading.
    func ready(wait: Bool = false) -> Model? {
        lock.lock()
        if let model { lock.unlock(); return model }
        if let retryAfter, retryAfter > .now { lock.unlock(); return nil }
        if wait && !loading {
            loading = true
            lock.unlock()
            load()
            return ready()
        }
        lock.unlock()
        if !wait { prewarm(); return nil }
        // Another thread is loading: wait for it briefly.
        for _ in 0..<200 {
            usleep(10_000)
            if Task.isCancelled { return nil }
            lock.lock(); let m = model; let l = loading; lock.unlock()
            if let m { return m }
            if !l { return nil }
        }
        return nil
    }

    var readiness: String {
        lock.lock(); defer { lock.unlock() }
        if model != nil { return "ready" }
        if loading { return "loading" }
        if let retryAfter, retryAfter > .now { return "retry-backoff" }
        return "cold"
    }

    static func resourceDirectory() -> URL? {
        RealWordFixer.resourceDirectory(containing: "tinynext-v2.q8")
    }

    // MARK: - Model

    final class Model: @unchecked Sendable {
        let vocabSize: Int, dim: Int, layerCount: Int, heads: Int, ffn: Int
        let headDim: Int
        let tokenizer: Tokenizer
        private let embed: [Float]
        private let finalNorm: [Float]
        private let layers: [Layer]
        private let cosTable: [Float], sinTable: [Float]
        static let maxPositions = 512

        struct Layer {
            let norm1: [Float], qkv: [Float], out: [Float], norm2: [Float], gateUp: [Float], down: [Float]
        }

        init?(directory: URL) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("tinynext-v2.q8"), options: .mappedIfSafe),
                  let tokenizer = Tokenizer(directory: directory) else { return nil }
            self.tokenizer = tokenizer
            var offset = 0
            func u32() -> Int? {
                guard offset + 4 <= data.count else { return nil }
                let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                offset += 4
                return Int(UInt32(littleEndian: v))
            }
            guard data.count > 28, data.prefix(4) == Data("TNX1".utf8) else { return nil }
            offset = 4
            guard let v = u32(), let d = u32(), let l = u32(), let h = u32(), let f = u32(), let count = u32(),
                  v > 0, v <= 100_000, d > 0, d <= 4096, l > 0, l <= 64,
                  h > 0, h <= d, f > 0, f <= 32768,
                  count == 2 + l * 6, d % h == 0, (d / h) % 2 == 0 else { return nil }
            vocabSize = v; dim = d; layerCount = l; heads = h; ffn = f; headDim = d / h
            func tensor(rows: Int, cols: Int) -> [Float]? {
                guard let kind = u32() else { return nil }
                if kind == 0 {
                    let n = rows * cols
                    guard offset + n * 4 <= data.count else { return nil }
                    var out = [Float](repeating: 0, count: n)
                    out.withUnsafeMutableBytes { dst in
                        data.withUnsafeBytes { src in
                            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + n * 4)]))
                        }
                    }
                    offset += n * 4
                    return out
                }
                guard kind == 1, offset + rows * 4 + rows * cols <= data.count else { return nil }
                var scales = [Float](repeating: 0, count: rows)
                scales.withUnsafeMutableBytes { dst in
                    data.withUnsafeBytes { src in
                        dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[offset..<(offset + rows * 4)]))
                    }
                }
                offset += rows * 4
                var out = [Float](repeating: 0, count: rows * cols)
                data.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Int8.self)
                    out.withUnsafeMutableBufferPointer { dst in
                        vDSP_vflt8(base, 1, dst.baseAddress!, 1, vDSP_Length(rows * cols))
                        for r in 0..<rows {
                            var s = scales[r]
                            vDSP_vsmul(dst.baseAddress! + r * cols, 1, &s, dst.baseAddress! + r * cols, 1, vDSP_Length(cols))
                        }
                    }
                }
                offset += rows * cols
                return out
            }
            guard let e = tensor(rows: v, cols: d) else { return nil }
            embed = e
            var built: [Layer] = []
            for _ in 0..<l {
                guard let n1 = tensor(rows: 1, cols: d), let qkv = tensor(rows: 3 * d, cols: d),
                      let o = tensor(rows: d, cols: d), let n2 = tensor(rows: 1, cols: d),
                      let gu = tensor(rows: 2 * f, cols: d), let dn = tensor(rows: d, cols: f) else { return nil }
                built.append(Layer(norm1: n1, qkv: qkv, out: o, norm2: n2, gateUp: gu, down: dn))
            }
            layers = built
            guard let fn = tensor(rows: 1, cols: d) else { return nil }
            finalNorm = fn
            let half = headDim / 2
            var c = [Float](repeating: 0, count: Self.maxPositions * half)
            var s = c
            for p in 0..<Self.maxPositions {
                for i in 0..<half {
                    let inv = 1.0 / pow(10000.0, Double(2 * i) / Double(headDim))
                    c[p * half + i] = Float(cos(Double(p) * inv))
                    s[p * half + i] = Float(sin(Double(p) * inv))
                }
            }
            cosTable = c; sinTable = s
        }

        private func rmsNorm(_ x: UnsafeMutablePointer<Float>, rows: Int, weight: [Float], into y: UnsafeMutablePointer<Float>) {
            let n = vDSP_Length(dim)
            for r in 0..<rows {
                var ss: Float = 0
                vDSP_svesq(x + r * dim, 1, &ss, n)
                var scale = 1 / sqrtf(ss / Float(dim) + 1e-6)
                vDSP_vsmul(x + r * dim, 1, &scale, y + r * dim, 1, n)
                vDSP_vmul(y + r * dim, 1, weight, 1, y + r * dim, 1, n)
            }
        }

        /// y[rows, outDim] = x[rows, inDim] · W[outDim, inDim]^T
        private func linear(_ x: UnsafePointer<Float>, rows: Int, inDim: Int, _ w: [Float], outDim: Int,
                            into y: UnsafeMutablePointer<Float>, accumulate: Bool = false) {
            w.withUnsafeBufferPointer { wp in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outDim), Int32(inDim),
                            1, x, Int32(inDim), wp.baseAddress!, Int32(inDim), accumulate ? 1 : 0, y, Int32(outDim))
            }
        }

        /// Total log-probability of each token sequence (the end-of-text token is prepended as the start).
        /// Sequences are run together through the linear layers; attention stays within each sequence.
        func logProbabilities(_ sequences: [[Int32]]) -> [Float] {
            let seqs = sequences.map { Array(([0] + $0).prefix(Self.maxPositions)) }
            let lengths = seqs.map { $0.count - 1 }
            let total = lengths.reduce(0, +)
            guard total > 0 else { return sequences.map { _ in 0 } }
            var starts: [Int] = []
            var acc = 0
            for n in lengths { starts.append(acc); acc += n }
            var x = [Float](repeating: 0, count: total * dim)
            for (s, seq) in seqs.enumerated() {
                for t in 0..<lengths[s] {
                    let id = Int(seq[t])
                    let row = starts[s] + t
                    embed.withUnsafeBufferPointer { e in
                        x.withUnsafeMutableBufferPointer { xp in
                            (xp.baseAddress! + row * dim).update(from: e.baseAddress! + id * dim, count: dim)
                        }
                    }
                }
            }
            var normed = [Float](repeating: 0, count: total * dim)
            var qkv = [Float](repeating: 0, count: total * 3 * dim)
            var attended = [Float](repeating: 0, count: total * dim)
            var gateUp = [Float](repeating: 0, count: total * 2 * ffn)
            var hidden = [Float](repeating: 0, count: total * ffn)
            let maxLen = lengths.max() ?? 1
            var scores = [Float](repeating: 0, count: maxLen * maxLen)
            let half = headDim / 2
            let scale = 1 / sqrtf(Float(headDim))
            x.withUnsafeMutableBufferPointer { xb in
            normed.withUnsafeMutableBufferPointer { nb in
            qkv.withUnsafeMutableBufferPointer { qb in
            attended.withUnsafeMutableBufferPointer { ab in
            gateUp.withUnsafeMutableBufferPointer { gb in
            hidden.withUnsafeMutableBufferPointer { hb in
            scores.withUnsafeMutableBufferPointer { sb in
                let xp = xb.baseAddress!, np = nb.baseAddress!, qp = qb.baseAddress!, ap = ab.baseAddress!
                let gp = gb.baseAddress!, hp = hb.baseAddress!, sp = sb.baseAddress!
                for layer in layers {
                    rmsNorm(xp, rows: total, weight: layer.norm1, into: np)
                    linear(np, rows: total, inDim: dim, layer.qkv, outDim: 3 * dim, into: qp)
                    // Rotary position on q and k, per sequence position.
                    cosTable.withUnsafeBufferPointer { cb in
                    sinTable.withUnsafeBufferPointer { snb in
                        for (s, n) in lengths.enumerated() {
                            for t in 0..<n {
                                let row = qp + (starts[s] + t) * 3 * dim
                                let c = cb.baseAddress! + t * half, sn = snb.baseAddress! + t * half
                                for part in 0..<2 {
                                    for h in 0..<heads {
                                        let v = row + part * dim + h * headDim
                                        for i in 0..<half {
                                            let a = v[i], b = v[i + half]
                                            v[i] = a * c[i] - b * sn[i]
                                            v[i + half] = b * c[i] + a * sn[i]
                                        }
                                    }
                                }
                            }
                        }
                    }
                    }
                    for (s, n) in lengths.enumerated() {
                        let base = qp + starts[s] * 3 * dim
                        for h in 0..<heads {
                            let q = base + h * headDim, k = base + dim + h * headDim, v = base + 2 * dim + h * headDim
                            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(headDim),
                                        scale, q, Int32(3 * dim), k, Int32(3 * dim), 0, sp, Int32(n))
                            for i in 0..<n {
                                let row = sp + i * n
                                var maxV: Float = -.greatestFiniteMagnitude
                                vDSP_maxv(row, 1, &maxV, vDSP_Length(i + 1))
                                var neg = -maxV
                                vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(i + 1))
                                var count = Int32(i + 1)
                                vvexpf(row, row, &count)
                                var sum: Float = 0
                                vDSP_sve(row, 1, &sum, vDSP_Length(i + 1))
                                var inv = 1 / sum
                                vDSP_vsmul(row, 1, &inv, row, 1, vDSP_Length(i + 1))
                                if i + 1 < n { (row + i + 1).update(repeating: 0, count: n - i - 1) }
                            }
                            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(headDim), Int32(n),
                                        1, sp, Int32(n), v, Int32(3 * dim), 0, ap + starts[s] * dim + h * headDim, Int32(dim))
                        }
                    }
                    linear(ap, rows: total, inDim: dim, layer.out, outDim: dim, into: xp, accumulate: true)
                    rmsNorm(xp, rows: total, weight: layer.norm2, into: np)
                    linear(np, rows: total, inDim: dim, layer.gateUp, outDim: 2 * ffn, into: gp)
                    for r in 0..<total {
                        let g = gp + r * 2 * ffn, u = g + ffn, out = hp + r * ffn
                        // silu(g) * u = g * u / (1 + exp(-g))
                        var count = Int32(ffn)
                        var minus: Float = -1
                        vDSP_vsmul(g, 1, &minus, out, 1, vDSP_Length(ffn))
                        vvexpf(out, out, &count)
                        var one: Float = 1
                        vDSP_vsadd(out, 1, &one, out, 1, vDSP_Length(ffn))
                        vDSP_vdiv(out, 1, g, 1, out, 1, vDSP_Length(ffn))
                        vDSP_vmul(out, 1, u, 1, out, 1, vDSP_Length(ffn))
                    }
                    linear(hp, rows: total, inDim: ffn, layer.down, outDim: dim, into: xp, accumulate: true)
                }
                rmsNorm(xp, rows: total, weight: finalNorm, into: np)
            }}}}}}}
            var logits = [Float](repeating: 0, count: total * vocabSize)
            normed.withUnsafeBufferPointer { nb in
                logits.withUnsafeMutableBufferPointer { lb in
                    linear(nb.baseAddress!, rows: total, inDim: dim, embed, outDim: vocabSize, into: lb.baseAddress!)
                }
            }
            var result: [Float] = []
            logits.withUnsafeMutableBufferPointer { lb in
                for (s, n) in lengths.enumerated() {
                    var sum: Float = 0
                    for t in 0..<n {
                        let row = lb.baseAddress! + (starts[s] + t) * vocabSize
                        var maxV: Float = 0
                        vDSP_maxv(row, 1, &maxV, vDSP_Length(vocabSize))
                        let target = row[Int(seqs[s][t + 1])]
                        var neg = -maxV
                        vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(vocabSize))
                        var count = Int32(vocabSize)
                        vvexpf(row, row, &count)
                        var z: Float = 0
                        vDSP_sve(row, 1, &z, vDSP_Length(vocabSize))
                        sum += target - maxV - logf(z)
                    }
                    result.append(sum)
                }
            }
            return result
        }

        /// Bound temporary logits/activation storage by the token rows, not just the number of candidates.
        /// Sequences have independent attention, so splitting a batch preserves their scores.
        func score(_ texts: [String]) -> [Float] {
            var results: [Float] = []
            var batch: [[Int32]] = []
            var rows = 0
            func flush() {
                guard !batch.isEmpty else { return }
                if Task.isCancelled { results += Array(repeating: .nan, count: batch.count) }
                else { results += logProbabilities(batch) }
                batch.removeAll(keepingCapacity: true)
                rows = 0
            }
            // A single context is already limited to maxPositions. Keep the
            // normal short-candidate batch fast, but don't allocate huge logits.
            let rowLimit = max(Self.maxPositions, min(1024, 4_000_000 / vocabSize))
            for text in texts {
                if Task.isCancelled { return Array(repeating: .nan, count: texts.count) }
                let tokens = Array(tokenizer.encode(text).prefix(Self.maxPositions - 1))
                let size = tokens.count
                if !batch.isEmpty && rows + size > rowLimit { flush() }
                // A mismatched tokenizer must never index past the weight matrix.
                if tokens.contains(where: { $0 < 0 || Int($0) >= vocabSize }) {
                    flush()
                    results.append(.nan)
                } else {
                    batch.append(tokens)
                    rows += size
                }
            }
            flush()
            return results
        }
    }

    // MARK: - Byte-level BPE tokenizer (GPT-2 style)

    final class Tokenizer: @unchecked Sendable {
        private let ids: [String: Int32]
        private let ranks: [String: Int]
        private let byteMap: [Character]
        private var cache: [String: [Int32]] = [:]
        private let cacheLock = NSLock()
        private static let pattern = try! NSRegularExpression(
            pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)

        init?(directory: URL) {
            guard let vocab = try? String(contentsOf: RealWordFixer.resourceFile("tinynext-vocab.txt", in: directory), encoding: .utf8),
                  let merges = try? String(contentsOf: RealWordFixer.resourceFile("tinynext-merges.txt", in: directory), encoding: .utf8)
            else { return nil }
            var ids: [String: Int32] = [:]
            for (i, token) in vocab.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !token.isEmpty {
                ids[String(token)] = Int32(i)
            }
            var ranks: [String: Int] = [:]
            for (i, line) in merges.split(separator: "\n").enumerated() { ranks[String(line)] = i }
            guard ids.count > 1000, ranks.count > 1000 else { return nil }
            self.ids = ids
            self.ranks = ranks
            var bs = Array(33...126) + Array(161...172) + Array(174...255)
            var cs = bs
            var n = 0
            for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
            var map = [Character](repeating: " ", count: 256)
            for (b, c) in zip(bs, cs) { map[b] = Character(Unicode.Scalar(UInt32(c))!) }
            byteMap = map
        }

        func encode(_ text: String) -> [Int32] {
            let ns = text as NSString
            var out: [Int32] = []
            for match in Self.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let piece = ns.substring(with: match.range)
                out += bpe(String(piece.utf8.map { byteMap[Int($0)] }))
            }
            return out
        }

        private func bpe(_ word: String) -> [Int32] {
            cacheLock.lock()
            if let hit = cache[word] { cacheLock.unlock(); return hit }
            cacheLock.unlock()
            var parts = word.map { String($0) }
            while parts.count > 1 {
                var best = Int.max, at = -1
                for i in 0..<(parts.count - 1) {
                    if let r = ranks[parts[i] + " " + parts[i + 1]], r < best { best = r; at = i }
                }
                guard at >= 0 else { break }
                parts[at] += parts[at + 1]
                parts.remove(at: at + 1)
            }
            let result = parts.map { ids[$0] ?? 0 }
            cacheLock.lock()
            if cache.count > 20_000 { cache.removeAll() }
            cache[word] = result
            cacheLock.unlock()
            return result
        }
    }
}
