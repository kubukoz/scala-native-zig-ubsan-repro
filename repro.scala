//> using scala 3.8.4
//> using platform native
//> using nativeVersion 0.5.12

// Minimal reproduction for an aarch64 Immix GC "misaligned address" panic seen
// when a Scala Native binary is cross-compiled with zig-as-clang
// (`zig cc -target aarch64-linux-gnu.<glibc>`). NO library dependencies — this
// is pure allocation churn to force Immix's conservative stack scan.
//
// Expected on a healthy binary: prints "ok: <n>" and exits 0.
// Expected on the faulting toolchain: panic in Marker_markRange
//   "load of misaligned address … for type 'word_t *' which requires 8 byte
//   alignment" during Heap_Collect, abort.
//
// Immix (the default GC) walks the program stack as aligned word_t's. The crash
// is a codegen/instrumentation property of the toolchain, not of this program's
// logic — so we keep the logic trivial and just guarantee GC runs with live
// references on the stack.

object repro {

  // Recurse so several frames' worth of live object references sit on the stack
  // while allocation churn triggers GC — that's what the conservative marker
  // scans. Returns an accumulated length so nothing is dead-code-eliminated.
  def churn(depth: Int, acc: Long): Long = {
    // A live heap object held in a local (on the stack across the alloc loop).
    val live = new Array[Byte](1024)
    live(0) = (depth & 0xff).toByte

    var i    = 0
    var sum  = acc + live.length
    while (i < 4096) {
      // Short-lived garbage → forces Immix to collect.
      val junk = new Array[Byte](2048)
      junk(i % junk.length) = i.toByte
      sum += junk(i % junk.length).toLong
      i += 1
    }

    if (depth <= 0) sum + live(0).toLong
    else churn(depth - 1, sum)
  }

  def main(args: Array[String]): Unit = {
    // Enough total allocation (~depth * 4096 * 2KB) to guarantee many GC cycles.
    val result = churn(64, 0L)
    println(s"ok: $result")
  }

}
