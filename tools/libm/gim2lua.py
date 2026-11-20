#!/usr/bin/env python3
"""gim2lua.py - translate GCC's optimized GIMPLE of glibc's math routines into Lua 5.4, for the SWMM6 Lua port.

  gim2lua.py OUT DUMP... --tables TABLES.json [--name NAME=LOCAL ...] [--header LINE ...]

The SWMM6 Lua port (lua/) calls the C library for the math functions Lua 5.4 has (exp, log, sin, cos, tan, asin, acos,
atan2, sqrt, fmod, log10, log2; Lua's ^ is pow except for the exponent 2, where it computes x * x). The others the
engine calls are translated from glibc 2.39 here: pow (for the exponent 2), atan (Lua's math.atan(x) is atan2(x, 1)),
sinh, cosh, tanh, expm1, log1p, cbrt and hypot, and exp, which sinh and cosh call. This is the SWMM5 ports' Lua back
end (swmm5-ports/tools/libm/gim2x.py, LuaEmitter) with what set 2 needs: GCC's unordered comparisons (u<, u<=, ord,
unord, ...), locals read through their default definition, frexp's out-parameter, operations on two constants, and
calls of sqrt, ldexp and the FMA exp. It reads the GIMPLE with this directory's gim2x.py (parser and Emitter, imported
unchanged). Every basic block is a label and every PHI a parallel assignment on its edge (Lua's multiple assignment
evaluates all right-hand sides first). The values:
  * f64: Lua floats; i64 and u64: Lua's 64-bit integers, which wrap as C's do (u64 held as its bit pattern; its <, <=,
    >, >= through math.ult); i32 and u32: Lua integers brought back into 32 bits after every operation that can leave
    them; bool: Lua booleans
  * Lua's >> is logical: an arithmetic shift of a signed value is written with ~ on both sides
  * bit casts through string.pack / string.unpack; fused multiply-adds through RT.fma, an exact emulation (glibm_rt.lua)
  * Lua allows 200 locals per function: the least-used variables of a larger function live in a table V
  * `return` must end a block in Lua: written `do return x end`; -0.0 and the integer -2^63 are names
The output is a chunk run in the port's shared environment E (lua/runswmm6.lua passes it as `...`); it defines
Glibm_<name> in E, the public functions, which pin down NaN results as tools/libm/gim2x.py's set-2 wrappers do.

Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md. The output is derived from glibc and so
licensed, like glibc's libm, under the GNU Lesser General Public License, version 2.1 or later.
"""
import collections, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gim2x                                                         # noqa: E402
from gim2x import (Emitter, parse, tkind, TYPES, INT_RE, FLOAT_RE, SSA_RE, TABLE_RE, FREXP,   # noqa: E402
                   UNORDERED, COMPARE_OPS)


def is_const(tok):
    t = tok.strip()
    return bool(INT_RE.match(t) or FLOAT_RE.match(t) or t in ('Inf', '-Inf'))


class LuaEmitter(Emitter):
    MAXLOCALS = 170

    def lit(self, tok, k):
        if k in ('f64', 'f32'):
            if tok in ('Inf', '-Inf'):
                return '(-INF)' if tok[0] == '-' else 'INF'
            if tok.endswith('Nan'):
                return 'QNAN'
            v = float(tok)
            if v == 0.0:
                return 'NZERO' if tok.startswith('-') else '0.0'
            s = repr(v)
            if 'e' not in s and '.' not in s and 'inf' not in s:
                s += '.0'
            return '(%s)' % s if s.startswith('-') else s
        n = int(tok)
        if k in ('i64', 'u64'):
            n &= 0xffffffffffffffff
            if n >= 1 << 63:
                n -= 1 << 64
            return 'MININT' if n == -(1 << 63) else ('(%d)' % n if n < 0 else str(n))
        if k == 'bool':
            return 'true' if n else 'false'
        n &= 0xffffffff
        if k != 'u32' and n >= 1 << 31:
            n -= 1 << 32
        return '(%d)' % n if n < 0 else str(n)

    def table(self, base, path, k):
        idx = re.findall(r'\[([^\]]+)\]', path)
        key = base + re.sub(r'\[[^\]]+\]', '[]', path)
        t = self.tables.get(key)
        if t is None:
            raise ValueError('table ' + key)
        self.used_tables.add(key)
        name = self.tprefix + re.sub(r'\W+', '_', key).strip('_')
        if not idx:
            return name
        ics = [self.opnd(i, 'i32')[0] for i in idx]
        flat = '(%s) * %d + (%s)' % (ics[0], t['dims'][1], ics[1]) if len(ics) == 2 else ics[0]
        return '%s[%s]' % (name, flat)

    @staticmethod
    def w32(code):
        return '((((%s) + 0x80000000) & 0xFFFFFFFF) - 0x80000000)' % code

    def conv(self, code, src, dst):
        if src == dst:
            return code
        if dst == 'bool':
            if src == 'f64':
                return '(%s ~= 0.0)' % code
            return '((%s & 1) ~= 0)' % code           # GIMPLE's (_Bool) keeps the low bit
        if src == 'bool':
            return '(%s and %s or %s)' % (code, '1.0' if dst == 'f64' else '1', '0.0' if dst == 'f64' else '0')
        if dst == 'f64':
            if src == 'u64':
                return 'RT.u64ToDouble(%s)' % code
            return '(%s * 1.0)' % code
        if src == 'f64':
            return {'i32': 'RT.d2i(%s)', 'u32': '(RT.d2l(%s) & 0xFFFFFFFF)', 'i64': 'RT.d2l(%s)', 'u64': 'RT.d2l(%s)'}[dst] % code
        if dst == 'i32':
            return self.w32(code)
        if dst == 'u32':
            return '(%s & 0xFFFFFFFF)' % code
        return code                                    # to i64 / u64: the same integer (or bit pattern)

    def wrap(self, code, k):
        if k == 'i32':
            return self.w32(code)
        if k == 'u32':
            return '((%s) & 0xFFFFFFFF)' % code
        return code

    def ucmp(self, ca, op, cb):
        """GIMPLE's comparisons that are true when an operand is a NaN, the ordered <> and the (un)ordered tests.
        Lua's <, <=, == on floats are C's (false when an operand is a NaN)."""
        if op == 'ord':
            return '(%s == %s)' % (ca, ca) if ca == cb else '(%s == %s and %s == %s)' % (ca, ca, cb, cb)
        if op == 'unord':
            return '(%s ~= %s)' % (ca, ca) if ca == cb else '(%s ~= %s or %s ~= %s)' % (ca, ca, cb, cb)
        if op == '<>':
            return '(%s < %s or %s < %s)' % (ca, cb, cb, ca)
        if op == 'u==':
            return '(not (%s < %s or %s < %s))' % (ca, cb, cb, ca)
        # u< is not (a >= b); u<= is not (a > b); u> is not (a <= b); u>= is not (a < b)
        return {'u<': '(not (%s <= %s))' % (cb, ca), 'u<=': '(not (%s < %s))' % (cb, ca),
                'u>': '(not (%s <= %s))' % (ca, cb), 'u>=': '(not (%s < %s))' % (ca, cb)}[op]

    def binop(self, a, op, b, k):
        if is_const(a) and FLOAT_RE.match(a.strip()) and op in ('+', '-', '*', '/'):
            # two floating-point constants (set 2: huge * huge, -two54 / zero): Lua folds neither NaN nor zero results
            return '(%s %s %s)' % (self.lit(a.strip(), 'f64'), op, self.opnd(b, 'f64')[0])
        ca, ka = self.opnd(a)
        cb, kb = self.opnd(b)
        shift = op in ('<<', '>>')
        if is_const(a):
            hint = k if (k and k != 'bool' and (shift or not is_const(b) and kb == k)) else kb
            if op in UNORDERED or op in ('==', '!=', '<', '<=', '>', '>='):
                hint = kb
            ca, ka = self.opnd(a, hint)
        if is_const(b):
            cb, kb = self.opnd(b, 'i32' if shift else ka)
        if op in UNORDERED:
            return self.ucmp(ca, op, cb)
        if op in ('==', '!=', '<', '<=', '>', '>='):
            lop = '~=' if op == '!=' else op
            if ka == 'u64' and op not in ('==', '!='):
                return {'<': 'm_ult(%s, %s)' % (ca, cb), '>': 'm_ult(%s, %s)' % (cb, ca),
                        '<=': '(not m_ult(%s, %s))' % (cb, ca), '>=': '(not m_ult(%s, %s))' % (ca, cb)}[op]
            if ka == 'u32' and op not in ('==', '!='):
                pass                                   # u32 values are held as non-negative integers: plain compare
            if ka == 'bool':
                return '(%s %s %s)' % (ca, lop, cb)
            return '(%s %s %s)' % (ca, lop, cb)
        if ka in ('f64', 'f32'):
            if op == '%':
                raise ValueError('float %')
            return '(%s %s %s)' % (ca, op, cb)
        if ka == 'bool':
            if op == '&':
                return '(%s and %s)' % (ca, cb)
            if op == '|':
                return '(%s or %s)' % (ca, cb)
            return '(%s ~= %s)' % (ca, cb)
        if op in ('&', '|', '^'):
            return '(%s %s %s)' % (ca, {'^': '~'}.get(op, op), cb)
        if op == '<<':
            return self.wrap('%s << %s' % (ca, cb), ka)
        if op == '>>':
            if ka in ('u32', 'u64'):
                return '(%s >> %s)' % (ca, cb)
            return '(%s >= 0 and (%s >> %s) or ~((~%s) >> %s))' % (ca, ca, cb, ca, cb)
        if op in ('/', '%'):
            if ka == 'i32' and op == '/':
                return 'RT.idiv(%s, %s)' % (ca, cb)       # C's division truncates toward zero
            if ka == 'i32' and op == '%':
                return 'RT.irem(%s, %s)' % (ca, cb)       # and its remainder takes the dividend's sign
            raise ValueError('integer %s (%s) in %s (not needed by the routines translated so far)' % (op, ka, self.f.name))
        return self.wrap('%s %s %s' % (ca, op, cb), ka)

    def expr(self, rhs, k):
        rhs = re.sub(r'\s*\[tail call\]$', '', rhs.strip())
        m = re.match(r'^\.(FMA|FNMA|FMS|FNMS) \((.*), (.*), (.*)\)$', rhs)
        if m:
            a, b, c = (self.opnd(x, 'f64')[0] for x in m.groups()[1:])
            op = m.group(1)
            if op in ('FNMA', 'FNMS'):
                a = '(-%s)' % a
            if op in ('FMS', 'FNMS'):
                c = '(-%s)' % c
            return 'fma(%s, %s, %s)' % (a, b, c)
        m = re.match(r'^__builtin_fma \((.*), (.*), (.*)\)$', rhs)
        if m:
            return 'fma(%s, %s, %s)' % tuple(self.opnd(x, 'f64')[0] for x in m.groups())
        m = re.match(r'^ABS_EXPR <(.*)>$', rhs)
        if m:
            c, ka = self.opnd(m.group(1), k)
            return 'm_abs(%s)' % c if ka in ('f64', 'f32') else self.wrap('m_abs(%s)' % c, ka)
        m = re.match(r'^(MIN|MAX)_EXPR <(.*), (.*)>$', rhs)
        if m:
            a, ka = self.opnd(m.group(2), k)
            b, kb = self.opnd(m.group(3), ka)
            if ka == 'u64':
                t = 'm_ult(%s, %s)' % ((a, b) if m.group(1) == 'MIN' else (b, a))
            else:
                t = '%s %s %s' % (a, '<' if m.group(1) == 'MIN' else '>', b)
            return '((%s) and %s or %s)' % (t, a, b)
        m = re.match(r'^VIEW_CONVERT_EXPR<(.*?)>\((.*)\)$', rhs)
        if m:
            dk = tkind(m.group(1))
            c, sk = self.opnd(m.group(2))
            if sk == 'f64' and dk in ('u64', 'i64'):
                return 'd2u(%s)' % c
            if sk in ('u64', 'i64') and dk == 'f64':
                return 'u2d(%s)' % c
            if sk == dk or {sk, dk} <= {'u64', 'i64'} or {sk, dk} <= {'u32', 'i32'}:
                return self.conv(c, sk, dk)
            raise ValueError('VIEW_CONVERT ' + rhs)
        m = re.match(r'^BIT_FIELD_REF <(.*), 32, (0|32)>$', rhs)
        if m:
            c, sk = self.opnd(m.group(1))
            assert sk == 'f64', rhs
            v = '(d2u(%s) >> 32)' % c if m.group(2) == '32' else '(d2u(%s) & 0xFFFFFFFF)' % c
            return v if k == 'u32' else self.w32(v)
        m = re.match(r'^\(([\w ]+)\) (\S+)$', rhs)
        if m and m.group(1).strip() in TYPES:
            c, sk = self.opnd(m.group(2))
            if sk is None:
                c, sk = self.opnd(m.group(2), 'f64' if FLOAT_RE.match(m.group(2)) else 'i32')
            return self.conv(c, sk, tkind(m.group(1)))
        m = re.match(r'^(\S+) (\+|-|\*|/|%|&|\||\^|<<|>>|' + COMPARE_OPS + r') (\S+)$', rhs)
        if m:
            return self.binop(m.group(1), m.group(2), m.group(3), k)
        m = re.match(r'^(-|~|!)(\S+)$', rhs)
        if m and not is_const(rhs):
            c, ka = self.opnd(m.group(2), k)
            op = m.group(1)
            if ka in ('f64', 'f32'):
                return '(-%s)' % c
            if op == '!':
                return '(not %s)' % c
            if op == '~':
                return self.wrap('~%s' % c, ka) if ka == 'u32' else '(~%s)' % c
            return self.wrap('-%s' % c, ka)
        m = re.match(r'^(\S+) \? (\S+) : (\S+)$', rhs)
        if m:
            cc, ck = self.opnd(m.group(1))
            a, _ = self.opnd(m.group(2), k)
            b, _ = self.opnd(m.group(3), k)
            c = self.conv(cc, ck, 'bool') if ck != 'bool' else cc
            if k == 'bool':
                return '((%s and %s) or (not %s and %s))' % (c, a, c, b)
            return '(%s and %s or %s)' % (c, a, b)
        m = re.match(r'^(\w+) \((.*)\)$', rhs)
        if m:
            fn = m.group(1)
            if fn == '__branred':
                raise ValueError('__branred (not needed by the routines translated here)')
            args = [x for x in m.group(2).split(', ') if x] if m.group(2).strip() else []
            pk = self.sigs.get(fn)
            cargs = []
            for i, x in enumerate(args):
                ek = pk[i] if pk and i < len(pk) else None
                c, xk = self.opnd(x, ek)
                if ek and xk and xk != ek:
                    c = self.conv(c, xk, ek)
                cargs.append(c)
            if fn not in self.rename:
                raise ValueError('call of %s in %s: no Lua name' % (fn, self.f.name))
            return '%s(%s)' % (re.sub(r'^R\.', 'RT.', self.rename[fn]), ', '.join(cargs))
        c, ka = self.opnd(rhs, k)
        if ka and k and ka != k:
            c = self.conv(c, ka, k)
        return c

    def function(self, f, sigs):
        self.f = f
        self.sigs = sigs
        self.params = {n: k for k, n in f.params}
        self.ssa_kind = {}
        self.infer(f, self.rets)
        fname = self.rename.get(f.name, f.name)
        assigned = collections.OrderedDict()
        for b, stmts in f.blocks.items():
            for s in stmts:
                m = re.match(r'^(?:# )?([\w.]+(?:\(D\))?) = ', s)
                if m and '{CLOBBER' not in s and not s.startswith('if ('):
                    nm = m.group(1)
                    if TABLE_RE.match(nm) and ('.' in nm and not SSA_RE.match(nm)):
                        continue
                    assigned[self.vname(nm)] = self.kind(nm)
        kinds = ('f64', 'f32', 'i32', 'u32', 'i64', 'u64', 'bool')
        for nm, k in f.decls.items():
            if not SSA_RE.match(nm) and not nm.startswith('_') or nm.startswith('__'):
                if k in kinds and self.vname(nm) not in assigned and not SSA_RE.match(nm):
                    assigned[self.vname(nm)] = k
        self.undef_locals(f, assigned)
        params = ['p_' + n for _, n in f.params]
        assigned = collections.OrderedDict((v, k) for v, k in assigned.items() if v not in params)
        order = list(f.blocks)
        phi_in = {}
        for b in order:
            lst = []
            for s in f.blocks[b]:
                if not s.startswith('# '):
                    continue
                m = re.match(r'^# (\S+) = PHI <(.*)>$', s)
                lhs = m.group(1)
                lk = self.kind(lhs)
                arms = {}
                for arm in re.findall(r'([^,(]+(?:\(D\))?)\((\d+)\)', m.group(2)):
                    val, frm = arm[0].strip(), int(arm[1])
                    c, vk = self.opnd(val, lk)
                    if vk and vk != lk:
                        c = self.conv(c, vk, lk)
                    arms[frm] = c
                lst.append((self.vname(lhs), lk, arms))
            phi_in[b] = lst
        targets = set()

        def jump(frm, to, ind):
            targets.add(to)
            lines = []
            ph = phi_in.get(to) or []
            if ph:
                missing = [v for v, _, arms in ph if frm not in arms]
                if missing:
                    raise ValueError('edge %d -> %d has no PHI argument for %s in %s' % (frm, to, missing, f.name))
                lines.append('%s%s = %s' % (ind, ', '.join(v for v, _, _ in ph), ', '.join(arms[frm] for _, _, arms in ph)))
            lines.append('%sgoto bb%d' % (ind, to))
            return lines

        blocks = []
        for bi, b in enumerate(order):
            body = '  '
            lines = []
            si = [s for s in f.blocks[b] if not s.startswith('# ')]
            ended = False
            i = 0
            while i < len(si):
                s = si[i]
                i += 1
                if '{CLOBBER' in s or s.startswith('__asm__') or re.match(r'^(<L\d+>|\w+):$', s) or s.startswith('//'):
                    continue
                m = re.match(r'^if \((.*)\)$', s)
                if m:
                    cond = m.group(1)
                    cm = re.match(r'^(\S+) (' + COMPARE_OPS + r') (\S+)$', cond)
                    if cm:
                        cc = self.binop(cm.group(1), cm.group(2), cm.group(3), 'bool')
                    else:
                        c, ck = self.opnd(cond)
                        cc = self.conv(c, ck, 'bool')
                    t1 = int(re.match(r'^goto <bb (\d+)>', si[i]).group(1))
                    assert si[i + 1] == 'else', si[i + 1]
                    t2 = int(re.match(r'^goto <bb (\d+)>', si[i + 2]).group(1))
                    i += 3
                    lines.append('%sif %s then' % (body, cc))
                    lines += jump(b, t1, body + '  ')
                    lines.append('%send' % body)
                    lines += jump(b, t2, body)
                    ended = True
                    break
                m = re.match(r'^goto <bb (\d+)>;', s)
                if m:
                    lines += jump(b, int(m.group(1)), body)
                    ended = True
                    break
                m = re.match(r'^return(?: (.*))?;$', s)
                if m:
                    if m.group(1):
                        c, rk = self.opnd(m.group(1), f.ret)
                        if rk and rk != f.ret:
                            c = self.conv(c, rk, f.ret)
                        lines.append('%sdo return %s end' % (body, c))
                    else:
                        lines.append('%sdo return end' % body)
                    ended = True
                    break
                m = re.match(r'^([\w.]+) = (\w+) \((\S+), &(\w+)\);$', s)
                if m and m.group(2) in FREXP:
                    # frexp(x, &e) (set 2: cbrt): the mantissa, then the exponent, from two pure runtime functions
                    x, _ = self.opnd(m.group(3), 'f64')
                    lines.append('%s%s = RT.frexp(%s); l_%s = RT.frexpExp(%s)' % (body, self.vname(m.group(1)), x, m.group(4), x))
                    continue
                m = re.match(r'^([\w.]+(?:\(D\))?) = (.*);$', s)
                if m:
                    lhs, rhs = m.group(1), m.group(2)
                    lines.append('%s%s = %s' % (body, self.vname(lhs), self.expr(rhs, self.kind(lhs))))
                    continue
                m = re.match(r'^(\w+) \((.*)\);$', s)
                if m:
                    lines.append('%slocal _ = %s' % (body, self.expr(s[:-1], None)))
                    continue
                raise ValueError('statement %r in %s' % (s, f.name))
            if not ended:
                lines += jump(b, order[bi + 1], body)
            blocks.append((b, lines))
        if phi_in.get(order[0]):
            raise ValueError('PHI in the entry block of %s' % f.name)
        code = []
        for b, lines in blocks:
            if b in targets:
                code.append('  ::bb%d::' % b)
            code += lines
        # Lua's limit of 200 locals: the most-used variables are locals, the rest live in the table V
        text = '\n'.join(code)
        uses = collections.Counter(re.findall(r'\b[A-Za-z_]\w*\b', text))
        names = sorted(assigned, key=lambda v: -uses[v])
        keep = names[:max(0, self.MAXLOCALS - len(params))]
        spill = names[len(keep):]
        zero = {'f64': '0.0', 'f32': '0.0', 'i32': '0', 'u32': '0', 'i64': '0', 'u64': '0', 'bool': 'false'}
        out = ['function %s(%s)' % (fname, ', '.join(params))]        # declared local at the top of the file
        keep_in_order = [v for v in assigned if v in keep]
        for i in range(0, len(keep_in_order), 8):
            ch = keep_in_order[i:i + 8]
            out.append('  local %s = %s' % (', '.join(ch), ', '.join(zero[assigned[v]] for v in ch)))
        if spill:
            idx = {v: i + 1 for i, v in enumerate(spill)}
            out.append('  local V = {%s}  -- %s' % (', '.join(zero[assigned[v]] for v in spill), ', '.join(spill)))
            text = re.sub(r'\b(%s)\b' % '|'.join(re.escape(v) for v in sorted(spill, key=len, reverse=True)),
                          lambda mm: 'V[%d]' % idx[mm.group(1)], text)
        out.append(text)
        out.append('end')
        self.exported = getattr(self, 'exported', []) + [fname]
        return '\n'.join(out)


# The public functions, defined in the port's environment E. pow and atan are glibc's pow and atan symbols themselves
# (pow@GLIBC_2.29 has no wrapper; atan never had one). Set 2's public symbols are the routines themselves or SVID
# wrappers that change no value (tools/libm/README.md); as there, the wrappers pin down NaN results, which IEEE leaves
# open and x86 decides by operand order: a NaN argument comes back quieted, and hypot gives x's when both are NaNs.
PUBLIC = '''
local quiet = RT.quiet
E.Glibm_exp, E.Glibm_pow, E.Glibm_atan = exp, pow, atan
function E.Glibm_sinh(x) if x ~= x then return quiet(x) end return sinh_t(x) end
function E.Glibm_cosh(x) if x ~= x then return quiet(x) end return cosh_t(x) end
function E.Glibm_tanh(x) if x ~= x then return quiet(x) end return tanh_t(x) end
function E.Glibm_expm1(x) if x ~= x then return quiet(x) end return expm1_t(x) end
function E.Glibm_log1p(x) if x ~= x then return quiet(x) end return log1p_t(x) end
function E.Glibm_cbrt(x) if x ~= x then return quiet(x) end return cbrt_t(x) end
function E.Glibm_hypot(x, y) if x ~= x and y ~= y then return quiet(x) end return hypot_t(x, y) end
'''


def main():
    args = sys.argv[1:]
    outp = args[0]
    dumps, tables, rename, header = [], {}, {}, []
    i = 1
    while i < len(args):
        if args[i] == '--tables':
            tables = json.load(open(args[i + 1]))
            i += 2
        elif args[i] == '--name':
            a, b = args[i + 1].split('=')
            rename[a] = b
            i += 2
        elif args[i] == '--header':
            header.append(args[i + 1])
            i += 2
        else:
            dumps.append(args[i])
            i += 1
    funcs = [f for d in dumps for f in parse(d)]
    sigs = {f.name: [k for k, _ in f.params] for f in funcs}
    sigs.update({'__math_oflow': ['u32'], '__math_uflow': ['u32'], '__math_may_uflow': ['u32'],
                 '__math_divzero': ['u32'], '__math_invalid': ['f64'], '__math_check_oflow': ['f64'],
                 '__math_check_uflow': ['f64'], '__branred': None, 'copysign': ['f64', 'f64'],
                 'sqrt': ['f64'], 'my_ldexp': ['f64', 'i32'], 'my_exp_fma': ['f64']})
    rename.setdefault('sqrt', 'm_sqrt')           # C's sqrt and Lua's math.sqrt: the correctly rounded square root
    rename.setdefault('my_ldexp', 'RT.ldexp')
    rename['copysign'] = 'RT.copysign'
    for k in ('oflow', 'uflow', 'may_uflow', 'divzero', 'invalid', 'check_oflow', 'check_uflow'):
        rename['__math_' + k] = 'RT.math_' + k
    for f in funcs:
        rename.setdefault(f.name, f.name)
    em = LuaEmitter('lua', tables, rename, 'T_')
    em.rets = {f.name: f.ret for f in funcs}
    em.rets.update({'__branred': 'i32', 'copysign': 'f64', 'sqrt': 'f64', 'my_ldexp': 'f64', 'my_exp_fma': 'f64'})
    em.rets.update({'__math_' + k: 'f64' for k in ('oflow', 'uflow', 'may_uflow', 'divzero', 'invalid', 'check_oflow', 'check_uflow')})
    bodies = [em.function(f, sigs) for f in funcs]
    head = []
    for key in sorted(em.used_tables):
        t = tables[key]
        name = 'T_' + re.sub(r'\W+', '_', key).strip('_')
        hexs = ''.join(t['data'])
        if not t['dims']:
            head.append('local %s = %s' % (name, ('u2d(0x%s)' % hexs) if t['kind'] == 'f64' else '0x' + hexs))
        else:
            head.append('local %s = RT.%s("%s")' % (name, 'f64tab' if t['kind'] == 'f64' else 'u64tab', hexs))
    hx = ''.join('-- %s\n' % h for h in header)
    text = ('-- Generated by tools/libm/gim2lua.py from GCC\'s optimized GIMPLE of glibc 2.39 (sysdeps/ieee754/dbl-64),\n'
            '-- compiled as glibc compiles its x86-64 FMA variants. Do not edit; regenerate (lua/make_glibm.sh).\n' + hx +
            'local m_abs, m_sqrt, m_ult, MININT = math.abs, math.sqrt, math.ult, math.mininteger\n'
            'local E = ...\n'
            'local RT = E.GlibmRT\n'
            'local _ENV = E\n'
            'local d2u, u2d, fma = RT.d2u, RT.u2d, RT.fma\n'
            'local INF, QNAN, NZERO = RT.INF, RT.QNAN, RT.NZERO\n\n'
            + '\n'.join(head) + '\n\nlocal %s\n\n' % ', '.join(em.exported) + '\n\n'.join(bodies) + '\n' + PUBLIC)
    open(outp, 'w').write(text)
    print('translated', [rename.get(f.name, f.name) for f in funcs], 'tables', len(em.used_tables))


if __name__ == '__main__':
    main()
