# main.mojo - the SWMM6 command line (src/cli/main.cpp, by way of the C# port's Program.cs): the same calls into the
# engine's C API in the same order, the same messages on standard output and the same exit code.
#   openswmm <input.inp> <report.rpt> [output.out]
# Written by Claude (Anthropic) for the SWMM6 ports; see README.md and ../AI-USE.md.

from std.sys import argv, exit
from std.ffi import external_call
from rt.core import *
from rt.crt import *
from rt.str import *
from rt.cont import *
from rt.rlib import *
from gen.engine import *

comptime VERSION = "6.0.0-alpha.4"


def out(s: StaticString) raises:
    _ = R.fprintf(r_stdout(), rt_lit("%s"), astr(rt_lit(s).p))


def out(s: CPtr) raises:
    _ = R.fprintf(r_stdout(), rt_lit("%s"), astr(s.p))


def cstr(s: StringSlice) -> CPtr:
    var b = s.as_bytes()
    var p = gc_atomic_bytes(len(b) + 1).unsafe_bitcast[Int8]()
    for k in range(len(b)):
        p[unsafe_offset=k] = Int8(b[k])
    return CPtr(p)


def msg(engine: Obj) raises -> CPtr:
    var p = F___swmm_get_last_error_msg(engine)
    if p.isnull():
        return rt_lit("(null)")
    return p


def run() raises -> Int32:
    engine_static_init()
    var args = argv()
    var argc = len(args) - 1
    if argc < 1:
        out("\nError: not enough arguments. Use --help for usage.\n\n")
        return 1
    if args[1] == "--version" or args[1] == "-v":
        out("openswmm.engine 6.0.0-alpha.4\n")
        return 0
    if argc < 2:
        out("\nError: need at least input and report file paths.\n")
        out("Usage: openswmm <input.inp> <report.rpt> [output.out]\n\n")
        return 1
    var inp = cstr(args[1])
    var rpt = cstr(args[2])
    var outf = cstr(args[3]) if argc > 2 else cstr("")
    out("\n... OpenSWMM Engine 6.0.0-alpha.4\n... Input: ")
    out(inp)
    out("\n... Report: ")
    out(rpt)
    out("\n... Output: ")
    out(outf)
    out("\n")
    _ = R.fflush(r_stdout())
    var t0 = TimePoint.now()
    var engine = F___swmm_engine_create()
    if engine.isnull():
        out("Error: failed to create engine instance.\n")
        return 1
    var err = F___swmm_engine_open(engine, inp, rpt, outf, CPtr())
    if err != 0:
        out("Error opening input file: ")
        out(msg(engine))
        out("\n")
        F___swmm_engine_destroy(engine)
        return err
    err = F___swmm_engine_initialize(engine)
    if err != 0:
        out("Error initializing: ")
        out(msg(engine))
        out("\n")
        _ = F___swmm_engine_close(engine)
        F___swmm_engine_destroy(engine)
        return err
    var save = Int32(1) if outf.p[] != 0 else Int32(0)
    err = F___swmm_engine_start(engine, save)
    if err != 0:
        out("Error starting simulation: ")
        out(msg(engine))
        out("\n")
        _ = F___swmm_engine_close(engine)
        F___swmm_engine_destroy(engine)
        return err
    var elapsed = Ary[Float64].make(1)
    var steps: Int64 = 0
    while True:
        err = F___swmm_engine_step(engine, Ptr[Float64](elapsed.p))
        if err != 0:
            _ = R.fprintf(r_stdout(), rt_lit("\nError at step %ld: %s\n"), al(steps), astr(msg(engine).p))
            break
        if elapsed[0] <= 0.0:
            break
        steps += 1
    _ = R.fprintf(r_stdout(), rt_lit("\n... %ld steps completed.\n"), al(steps))
    var result = err
    var st = F___swmm_engine_end(engine)
    if st != 0:
        _ = R.fprintf(r_stdout(), rt_lit("Error ending simulation: %s\n"), astr(msg(engine).p))
        if result == 0:
            result = st
    st = F___swmm_engine_report(engine)
    if st != 0:
        _ = R.fprintf(r_stdout(), rt_lit("Error writing report: %s\n"), astr(msg(engine).p))
        if result == 0:
            result = st
    st = F___swmm_engine_close(engine)
    if st != 0:
        _ = R.fprintf(r_stdout(), rt_lit("Error closing simulation: %s\n"), astr(msg(engine).p))
        if result == 0:
            result = st
    F___swmm_engine_destroy(engine)
    var secs = TimePoint.op_sub(TimePoint.now(), t0).count()
    _ = R.fprintf(r_stdout(), rt_lit("... OpenSWMM Engine %s in %.2f seconds.\n\n"), astr((rt_lit("completed") if result == 0 else rt_lit("failed")).p), ad(secs))
    return result


def main():
    rt_init()
    crt_init()
    rlib_init()
    var rc: Int32 = 0
    try:
        rc = run()
    except:
        var e = rt_exc_get()
        try:
            var w = e[].what() if not e.isnull() else rt_lit("")
            _ = R.fprintf(r_stdout(), rt_lit("\nterminate called after throwing an exception: %s\n"), astr(w.p))
        except:
            pass
        rc = 134
    flush_all()          # returning from main calls exit(), which flushes every open FILE
    exit(Int(rc) & 255)
