// MojoFn.cs - method bodies: C# statements (Roslyn IOperation trees) to Mojo.
// Mojo's statements are Python's: no switch, no labelled break, no goto, no block expressions. A switch is a chain
// of tests (inside a one-pass `while True:` when a case leaves early), a `for` repeats its increment before every
// continue, a goto (one function) is a loop over a program counter. A C# `ref` is a pointer: a local whose address
// is taken lives on the runtime's own stack (rt_salloc; lessons/74), one captured by a lambda in a collected cell.
// Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Mojo
{
    static int lambdaCount, thunkCount, helperCount;

    public sealed partial class Fn
    {
        readonly IMethodSymbol? method;
        readonly INamedTypeSymbol cls;
        readonly string retMojo;
        readonly bool retRef;
        readonly Dictionary<ISymbol, string> names = new(SymbolEqualityComparer.Default);
        readonly HashSet<ISymbol> refVars = new(SymbolEqualityComparer.Default);   // hold a pointer: x[]
        readonly HashSet<ISymbol> cells = new(SymbolEqualityComparer.Default);     // captured by a lambda: a collected cell, x[]
        readonly HashSet<ISymbol> slots = new(SymbolEqualityComparer.Default);     // address taken: the runtime stack, x[]
        readonly Dictionary<ISymbol, string> captured = new(SymbolEqualityComparer.Default);   // in a lambda: __c[].f[]
        readonly HashSet<string> used = new();
        readonly List<string> slotDecls = new();
        int tmp;
        readonly bool inLambda;
        bool capturesThis;
        bool hoist;
        readonly List<string> hoisted = new();
        readonly Dictionary<string, int> gotoLabels = new();
        string? rethrowVar;
        // break and continue targets, innermost last
        readonly List<Jump> jumps = new();

        sealed class Jump
        {
            public ILabelSymbol? Exit, Cont;
            public bool IsSwitch, Wrapped, IsDo;
            public string? DoCond;
            public List<string>? Post;
            public string? Flag;                 // a wrapped switch: set when a continue passes through it
            public ILabelSymbol? FlagTarget;
        }

        public Fn(IMethodSymbol? m, INamedTypeSymbol c, string ret)
        {
            method = m; cls = c; retMojo = ret; retRef = m != null && m.RefKind != RefKind.None;
            foreach (var r in Reserved) used.Add(r);
        }

        Fn(Fn parent, IMethodSymbol lambda)
        {
            inLambda = true;
            method = lambda; cls = parent.cls; retMojo = RetType(lambda); retRef = lambda.RefKind != RefKind.None;
            foreach (var r in Reserved) used.Add(r);
        }

        string Fresh(string b) { tmp++; return "__" + b + tmp; }

        string Declare(ISymbol s, string name)
        {
            var n = Id(name);
            if (n == "_") n = "__discard";
            if (n.StartsWith("__")) n = "v" + n;
            var b = n; int k = 2;
            while (used.Contains(n)) n = b + "_" + k++;
            used.Add(n);
            names[s] = n;
            return n;
        }

        static string Ind(int n) => new string(' ', 4 * n);

        /// <summary>A parameter in the function's head: a pointer for ref, a mutable copy otherwise (renamed when the
        /// body keeps it in a cell or a slot).</summary>
        public string ParamDecl(IParameterSymbol p)
        {
            if (p.RefKind != RefKind.None) return ParamName(p) + ": " + ParamType(p);
            return "var " + ParamName(p) + ": " + MojoType(p.Type);
        }

        readonly Dictionary<ISymbol, string> paramNames = new(SymbolEqualityComparer.Default);
        string ParamName(IParameterSymbol p)
        {
            if (paramNames.TryGetValue(p, out var n)) return n;
            n = Declare(p, p.Name);
            paramNames[p] = n;
            return n;
        }

        // -------------------------------------------------------------------------------------------- captures
        static List<ISymbol> CapturedBy(IAnonymousFunctionOperation lam, out bool usesThis)
        {
            var res = new List<ISymbol>();
            var seen = new HashSet<ISymbol>(SymbolEqualityComparer.Default);
            usesThis = false;
            foreach (var d in lam.Body.DescendantsAndSelf())
            {
                ISymbol? s = d switch { ILocalReferenceOperation l => l.Local, IParameterReferenceOperation p => p.Parameter, _ => null };
                if (d is IInstanceReferenceOperation ir && ir.ReferenceKind == InstanceReferenceKind.ContainingTypeInstance) usesThis = true;
                if (s == null || Within(s, lam.Symbol)) continue;
                if (seen.Add(s)) res.Add(s);
            }
            return res;
        }

        static bool Within(ISymbol s, IMethodSymbol lam)
        {
            for (var c = s.ContainingSymbol; c != null; c = c.ContainingSymbol)
                if (SymbolEqualityComparer.Default.Equals(c, lam)) return true;
            return false;
        }

        bool Mine(ISymbol s) => SymbolEqualityComparer.Default.Equals(s.ContainingSymbol, method);

        static ISymbol? VarOf(IOperation o)
        {
            while (o is IConversionOperation c && c.Conversion.IsIdentity) o = c.Operand;
            while (o is IParenthesizedOperation pp) o = pp.Operand;
            return o switch { ILocalReferenceOperation l when l.Local.RefKind == RefKind.None => l.Local, IParameterReferenceOperation p when p.Parameter.RefKind == RefKind.None => p.Parameter, _ => null };
        }

        /// <summary>Which of this function's own locals and parameters need a home in memory: captured by a lambda
        /// (a cell), or passed by ref, bound to a ref local, or assigned inside an expression (a slot).</summary>
        void FindHomes(IOperation body)
        {
            foreach (var lam in body.Descendants().OfType<IAnonymousFunctionOperation>())
                foreach (var s in CapturedBy(lam, out _))
                    if (Mine(s)) cells.Add(s);
            foreach (var d in body.Descendants())
            {
                if (d is IAnonymousFunctionOperation) continue;
                if (InsideLambda(d, body)) continue;
                ISymbol? s = null;
                switch (d)
                {
                    case IArgumentOperation a when a.Parameter != null && a.Parameter.RefKind != RefKind.None: s = VarOf(a.Value); break;
                    case IVariableDeclaratorOperation v when v.Symbol.RefKind != RefKind.None && v.Initializer != null: s = VarOf(v.Initializer.Value); break;
                    case ISimpleAssignmentOperation sa when sa.IsRef: s = VarOf(sa.Value); break;
                    case ISimpleAssignmentOperation sa2 when !(sa2.Parent is IExpressionStatementOperation) && !(sa2.Parent is IFieldInitializerOperation): s = VarOf(sa2.Target); break;
                    case ICompoundAssignmentOperation ca when !(ca.Parent is IExpressionStatementOperation): s = VarOf(ca.Target); break;
                    case IIncrementOrDecrementOperation inc when !(inc.Parent is IExpressionStatementOperation) && !IsForPost(inc): s = VarOf(inc.Target); break;
                }
                if (s != null && Mine(s) && !cells.Contains(s)) slots.Add(s);
            }
        }

        static bool IsForPost(IOperation o) => o.Parent is IExpressionStatementOperation;

        static bool InsideLambda(IOperation d, IOperation root)
        {
            for (var p = d.Parent; p != null && p != root; p = p.Parent) if (p is IAnonymousFunctionOperation) return true;
            return false;
        }

        // -------------------------------------------------------------------------------------------- bodies
        public string Body(IOperation op, IEnumerable<IParameterSymbol> ps, bool hasThis, bool isCtor = false)
        {
            var lines = new List<string>();
            if (hasThis && !inLambda) used.Add("this");
            FindHomes(op);
            var entry = new List<string>();
            foreach (var p in ps)
            {
                if (p.RefKind != RefKind.None) { ParamName(p); refVars.Add(p); continue; }
                var pn = ParamName(p);
                if (cells.Contains(p) || slots.Contains(p))
                {
                    var n = Fresh("h_" + p.Name);
                    used.Add(n);
                    if (cells.Contains(p)) entry.Add(Ind(1) + "var " + n + " = rt_cell[" + MojoType(p.Type) + "](" + pn + ")");
                    else { slotDecls.Add(Ind(1) + "var " + n + " = rt_salloc[" + MojoType(p.Type) + "]()"); entry.Add(Ind(1) + n + "[] = " + pn); }
                    names[p] = n;
                }
            }
            var ops = op is IBlockOperation b ? b.Operations.ToList() : op is IMethodBodyOperation mb && mb.BlockBody != null ? mb.BlockBody.Operations.ToList() : new List<IOperation> { op };
            hoist = op.Descendants().Any(d => d is IBranchOperation br && br.BranchKind == BranchKind.GoTo);
            var body = new List<string>();
            if (hoist) GotoBody(ops, body);
            else
            {
                if (op is not IBlockOperation && op is not IMethodBodyOperation && retMojo != "NoneType" && !isCtor && op is not IReturnOperation)
                {
                    var v = retRef ? Addr(op) : Value(op, method!.ReturnType);
                    body.Add(Ind(1) + "return " + v);
                }
                else Block(ops, body, 1);
            }
            if (HasSlotsSoFar()) lines.Add(Ind(1) + "var __sp = rt_sp()");
            lines.AddRange(slotDecls);
            lines.AddRange(entry);
            foreach (var h in hoisted) lines.Add(Ind(1) + h);
            lines.AddRange(body);
            // a function without a value that runs off its end gives back its runtime stack there too (without
            // this, a loop calling it fills the 8 MB stack)
            if ((retMojo == "NoneType" || isCtor) && HasSlotsSoFar() && !(EndsInJump(lines) && lines[^1].StartsWith(Ind(1)) && !lines[^1].StartsWith(Ind(2))))
                lines.Add(Ind(1) + "rt_set_sp(__sp)");
            if (retMojo != "NoneType" && !isCtor && !EndsInJump(lines)) lines.Add(Ind(1) + "raise rt_unreachable()");
            if (lines.Count == 0) lines.Add(Ind(1) + "pass");
            return string.Concat(lines.Select(l => l + "\n"));
        }

        bool HasSlots => slotDecls.Count > 0;

        /// <summary>The statements a return runs first: give back the runtime stack this function took.</summary>
        public string ReturnPrefix(string ind) => HasSlotsSoFar() ? ind + "rt_set_sp(__sp)\n" : "";

        static bool EndsInJump(List<string> lines)
        {
            if (lines.Count == 0) return false;
            var s = lines[^1].Trim();
            return s.StartsWith("return ") || s == "return" || s == "break" || s == "continue" || s.StartsWith("raise ");
        }

        void Block(IEnumerable<IOperation> ops, List<string> lines, int ind)
        {
            var list = ops.ToList();
            for (int i = 0; i < list.Count; i++)
            {
                if (list[i] is IUsingDeclarationOperation ud)
                {
                    UsingRest(ud, list.Skip(i + 1).ToList(), lines, ind);
                    return;
                }
                Stmt(list[i], lines, ind);
                if (EndsInJump(lines) && LastAtLevel(lines, ind)) return;
            }
        }

        static bool LastAtLevel(List<string> lines, int ind) => lines.Count > 0 && lines[^1].StartsWith(Ind(ind)) && !lines[^1].StartsWith(Ind(ind + 1));

        /// <summary>A nested body: at least `pass`.</summary>
        void Sub(IOperation op, List<string> lines, int ind)
        {
            int at = lines.Count;
            if (op is IBlockOperation b) Block(b.Operations, lines, ind);
            else Stmt(op, lines, ind);
            if (lines.Count == at) lines.Add(Ind(ind) + "pass");
        }

        void SubList(IEnumerable<IOperation> ops, List<string> lines, int ind)
        {
            int at = lines.Count;
            Block(ops, lines, ind);
            if (lines.Count == at) lines.Add(Ind(ind) + "pass");
        }

        void Stmt(IOperation op, List<string> lines, int ind)
        {
            try { StmtInner(op, lines, ind); }
            catch (Todo e)
            {
                lines.Add(Ind(ind) + "raise rt_todo(\"" + e.Message.Replace("\\", "\\\\").Replace("\"", "'") + "\")");
            }
        }

        void StmtInner(IOperation op, List<string> lines, int ind)
        {
            var p = Ind(ind);
            switch (op)
            {
                case IBlockOperation b: Block(b.Operations, lines, ind); return;
                case IVariableDeclarationGroupOperation g:
                    foreach (var d in g.Declarations)
                        foreach (var v in d.Declarators) LocalDecl(v, d.Initializer, lines, ind);
                    return;
                case IExpressionStatementOperation es: StmtExpr(es.Operation, lines, ind); return;
                case IReturnOperation r: Return(r, lines, ind); return;
                case IConditionalOperation c: If(c, lines, ind, false); return;
                case IWhileLoopOperation w: While(w, lines, ind); return;
                case IForLoopOperation f: For(f, lines, ind); return;
                case IForEachLoopOperation fe: ForEach(fe, lines, ind); return;
                case IBranchOperation br: Branch(br, lines, ind); return;
                case ILabeledOperation l:
                    if (l.Operation != null) Stmt(l.Operation, lines, ind);
                    return;
                case ISwitchOperation sw: Switch(sw, lines, ind); return;
                case ITryOperation t: Try(t, lines, ind); return;
                case IThrowOperation th:
                    if (th.Exception == null)
                    {
                        if (rethrowVar == null) Todo("throw; outside a catch");
                        lines.Add(p + "raise rt_throw(" + rethrowVar + ")");
                    }
                    else lines.Add(p + "raise rt_throw(" + ExcValue(th.Exception) + ")");
                    return;
                case IEmptyOperation: return;
                case IUsingDeclarationOperation ud: UsingRest(ud, new List<IOperation>(), lines, ind); return;
                case ILocalFunctionOperation: Todo("local function"); return;
                default: Todo("statement " + op.Kind); return;
            }
        }

        /// <summary>A thrown object as the runtime's exception reference.</summary>
        string ExcValue(IOperation e)
        {
            while (e is IConversionOperation cv && cv.IsImplicit) e = cv.Operand;
            var t = e.Type as INamedTypeSymbol;
            var v = X(e);
            if (t != null && IsEngine(t)) return ToRuntimeBase(v, t);
            return v;
        }

        string ToRuntimeBase(string v, INamedTypeSymbol t)
        {
            var c = t;
            while (c.BaseType != null && IsEngine(c.BaseType)) c = c.BaseType;
            if (c.BaseType == null || !IsRuntime(c.BaseType)) Todo("throw of a non-exception " + t.Name);
            return v + ".cast[CppException]()";
        }

        void LocalDecl(IVariableDeclaratorOperation v, IVariableInitializerOperation? outerInit, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var loc = v.Symbol;
            var init = v.Initializer ?? outerInit;
            if (loc.RefKind != RefKind.None)
            {
                var a = init == null ? Todo("ref local without initializer") : Addr(init.Value);
                var n = Declare(loc, loc.Name);
                refVars.Add(loc);
                var pt = "P[" + MojoType(loc.Type) + "]";
                if (hoist) { hoisted.Add("var " + n + " = rt_null[" + MojoType(loc.Type) + "]()"); lines.Add(p + n + " = " + a); return; }
                lines.Add(p + "var " + n + ": " + pt + " = " + a);
                return;
            }
            var mt = MojoType(loc.Type);
            string val = init == null ? Zero(loc.Type) : Value(init.Value, loc.Type);
            if (cells.Contains(loc))
            {
                var name0 = Declare(loc, loc.Name);
                if (hoist) Todo("captured local in a function with goto");
                lines.Add(p + "var " + name0 + " = rt_cell[" + mt + "](" + val + ")");
                return;
            }
            if (slots.Contains(loc))
            {
                var name1 = Declare(loc, loc.Name);
                slotDecls.Add(Ind(1) + "var " + name1 + " = rt_salloc[" + mt + "]()");
                lines.Add(p + name1 + "[] = " + val);
                return;
            }
            var name = Declare(loc, loc.Name);
            if (hoist)
            {
                hoisted.Add("var " + name + ": " + mt + " = " + Zero(loc.Type));
                if (init != null) lines.Add(p + name + " = " + val);
                return;
            }
            lines.Add(p + "var " + name + ": " + mt + " = " + val);
        }

        public void AssignInto(string name, IOperation value, ITypeSymbol t, List<string> lines, int ind)
        {
            lines.Add(Ind(ind) + name + " = " + Value(value, t));
        }

        void Return(IReturnOperation r, List<string> lines, int ind)
        {
            var p = Ind(ind);
            string? v = null;
            if (r.ReturnedValue != null) v = retRef ? Addr(r.ReturnedValue) : Value(r.ReturnedValue, method?.ReturnType);
            if (HasSlotsSoFar())
            {
                if (v != null && !IsTrivial(v)) { var t = Fresh("r"); lines.Add(p + "var " + t + " = " + v); v = t; }
                lines.Add(p + "rt_set_sp(__sp)");
            }
            lines.Add(p + "return" + (v != null ? " " + v : ""));
        }

        // a function's slots are known only after its body is read, so every return restores the stack when the
        // function has any slot at all (FindHomes ran first)
        bool HasSlotsSoFar() => slots.Count > 0 || slotDecls.Count > 0;

        static bool IsTrivial(string v) => System.Text.RegularExpressions.Regex.IsMatch(v, @"^[A-Za-z_][A-Za-z0-9_]*$") || System.Text.RegularExpressions.Regex.IsMatch(v, @"^[A-Za-z0-9_]+\([-0-9.e]+\)$");

        void If(IConditionalOperation c, List<string> lines, int ind, bool isElif)
        {
            var p = Ind(ind);
            lines.Add(p + (isElif ? "elif " : "if ") + X(c.Condition) + ":");
            Sub(c.WhenTrue, lines, ind + 1);
            if (c.WhenFalse == null) return;
            var wf = c.WhenFalse;
            if (wf is IBlockOperation bb && bb.Operations.Length == 1 && bb.Operations[0] is IConditionalOperation) wf = bb.Operations[0];
            if (wf is IConditionalOperation c2 && c2.Type == null) { If(c2, lines, ind, true); return; }
            lines.Add(p + "else:");
            Sub(wf, lines, ind + 1);
        }

        void LoopBody(IOperation body, Jump j, List<string> lines, int ind)
        {
            jumps.Add(j);
            Sub(body, lines, ind);
            jumps.RemoveAt(jumps.Count - 1);
        }

        void While(IWhileLoopOperation w, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var j = new Jump { Exit = w.ExitLabel, Cont = w.ContinueLabel };
            if (w.ConditionIsTop)
            {
                lines.Add(p + "while " + (w.Condition == null ? "True" : X(w.Condition)) + ":");
                LoopBody(w.Body, j, lines, ind + 1);
                return;
            }
            // do { body } while (cond): the test at the bottom, and before every continue
            var cond = X(w.Condition!);
            j.IsDo = true; j.DoCond = cond;
            lines.Add(p + "while True:");
            LoopBody(w.Body, j, lines, ind + 1);
            if (!(EndsInJump(lines) && LastAtLevel(lines, ind + 1)))
            {
                lines.Add(Ind(ind + 1) + "if not (" + cond + "):");
                lines.Add(Ind(ind + 2) + "break");
            }
        }

        void For(IForLoopOperation f, List<string> lines, int ind)
        {
            var p = Ind(ind);
            foreach (var b in f.Before) Stmt(b, lines, ind);
            var cond = f.Condition == null ? "True" : X(f.Condition);
            var posts = new List<string>();
            foreach (var a in f.AtLoopBottom)
            {
                var pl = new List<string>();
                if (a is IExpressionStatementOperation es) StmtExpr(es.Operation, pl, 0);
                else Stmt(a, pl, 0);
                posts.AddRange(pl);
            }
            var j = new Jump { Exit = f.ExitLabel, Cont = f.ContinueLabel, Post = posts };
            lines.Add(p + "while " + cond + ":");
            LoopBody(f.Body, j, lines, ind + 1);
            if (!(EndsInJump(lines) && LastAtLevel(lines, ind + 1)))
                foreach (var s in posts) lines.Add(Ind(ind + 1) + s);
        }

        void ForEach(IForEachLoopOperation fe, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var coll = fe.Collection is IConversionOperation cv && cv.IsImplicit ? cv.Operand : fe.Collection;
            var ct = coll.Type!;
            if (fe.LoopControlVariable is not IVariableDeclaratorOperation vd) { Todo("foreach variable"); return; }
            var loc = vd.Symbol;
            var mt = MojoType(loc.Type);
            var j = new Jump { Exit = fe.ExitLabel, Cont = fe.ContinueLabel };
            if (ct is IArrayTypeSymbol)
            {
                var a = Fresh("arr"); var i = Fresh("i");
                lines.Add(p + "var " + a + " = " + X(coll));
                lines.Add(p + "var " + i + " = 0");
                lines.Add(p + "while " + i + " < " + a + ".n:");
                Bind(loc, mt, a + "[" + i + "]", lines, ind + 1);
                lines.Add(Ind(ind + 1) + i + " += 1");
            }
            else
            {
                var it = Fresh("it");
                lines.Add(p + "var " + it + " = " + X(coll));
                lines.Add(p + "while " + it + ".next():");
                Bind(loc, mt, it + ".cur()", lines, ind + 1);
            }
            LoopBody(fe.Body, j, lines, ind + 1);
        }

        void Bind(ILocalSymbol loc, string mt, string v, List<string> lines, int ind)
        {
            var name = Declare(loc, loc.Name);
            if (cells.Contains(loc)) lines.Add(Ind(ind) + "var " + name + " = rt_cell[" + mt + "](" + v + ")");
            else if (slots.Contains(loc)) { slotDecls.Add(Ind(1) + "var " + name + " = rt_salloc[" + mt + "]()"); lines.Add(Ind(ind) + name + "[] = " + v); }
            else lines.Add(Ind(ind) + "var " + name + ": " + mt + " = " + v);
        }

        void Branch(IBranchOperation br, List<string> lines, int ind)
        {
            var p = Ind(ind);
            switch (br.BranchKind)
            {
                case BranchKind.Break:
                case BranchKind.Continue:
                    {
                        bool isBreak = br.BranchKind == BranchKind.Break;
                        int k = jumps.FindLastIndex(j => SymbolEqualityComparer.Default.Equals(isBreak ? j.Exit : j.Cont, br.Target));
                        if (k < 0) { Todo("jump target not found"); return; }
                        var tgt = jumps[k];
                        // wrapped switches between here and the target: leave each through its flag
                        for (int i = jumps.Count - 1; i > k; i--)
                        {
                            var w = jumps[i];
                            if (!w.IsSwitch) { Todo("jump out of a nested loop"); return; }
                            if (!w.Wrapped) continue;
                            if (w.Flag == null) { w.Flag = Fresh("jf"); }
                            if (w.FlagTarget != null && !SymbolEqualityComparer.Default.Equals(w.FlagTarget, br.Target)) { Todo("two jumps through one switch"); return; }
                            w.FlagTarget = br.Target;
                            lines.Add(p + w.Flag + " = True");
                            lines.Add(p + "break");
                            return;
                        }
                        if (isBreak)
                        {
                            if (tgt.IsSwitch && !tgt.Wrapped) { Todo("break inside an unwrapped switch"); return; }
                            lines.Add(p + "break");
                            return;
                        }
                        EmitContinue(tgt, lines, ind);
                        return;
                    }
                case BranchKind.GoTo:
                    if (!gotoLabels.TryGetValue(br.Target.Name, out var gk)) { Todo("goto into a nested statement"); return; }
                    if (jumps.Count > 0) { Todo("goto from inside a loop or switch"); return; }
                    lines.Add(p + "__pc = " + gk);
                    lines.Add(p + "continue");
                    return;
            }
            Todo("branch " + br.BranchKind);
        }

        void EmitContinue(Jump tgt, List<string> lines, int ind)
        {
            var p = Ind(ind);
            if (tgt.IsDo)
            {
                lines.Add(p + "if not (" + tgt.DoCond + "):");
                lines.Add(Ind(ind + 1) + "break");
                lines.Add(p + "continue");
                return;
            }
            if (tgt.Post != null) foreach (var s in tgt.Post) lines.Add(p + s);
            lines.Add(p + "continue");
        }

        /// <summary>A function with goto: its top-level statements cut at each label into the arms of a dispatch loop.</summary>
        void GotoBody(List<IOperation> ops, List<string> lines)
        {
            var segs = new List<List<IOperation>> { new() };
            foreach (var o in ops)
            {
                if (o is ILabeledOperation l)
                {
                    gotoLabels[l.Label.Name] = segs.Count;
                    segs.Add(new List<IOperation> { o });
                }
                else segs[^1].Add(o);
            }
            foreach (var d in ops.SelectMany(o => o.DescendantsAndSelf()).OfType<ILabeledOperation>())
                if (!gotoLabels.ContainsKey(d.Label.Name)) Todo("label inside a nested statement");
            hoisted.Add("var __pc = 0");
            lines.Add(Ind(1) + "while True:");
            for (int i = 0; i < segs.Count; i++)
            {
                lines.Add(Ind(2) + (i == 0 ? "if" : "elif") + " __pc == " + i + ":");
                var seg = new List<string>();
                Block(segs[i], seg, 3);
                lines.AddRange(seg);
                if (!(EndsInJump(seg) && LastAtLevel(seg, 3)))
                {
                    if (i + 1 < segs.Count) { lines.Add(Ind(3) + "__pc = " + (i + 1)); lines.Add(Ind(3) + "continue"); }
                    else lines.Add(Ind(3) + "break");
                }
            }
            lines.Add(Ind(2) + "else:");
            lines.Add(Ind(3) + "raise rt_unreachable()");
        }

        /// <summary>A break that leaves the switch before the end of its case (not the case's last statement).</summary>
        static bool HasInnerBreak(ISwitchOperation sw)
        {
            foreach (var c in sw.Cases)
            {
                var body = c.Body.ToList();
                for (int i = 0; i < body.Count; i++)
                {
                    bool last = i == body.Count - 1;
                    foreach (var d in body[i].DescendantsAndSelf().OfType<IBranchOperation>())
                        if (d.BranchKind == BranchKind.Break && SymbolEqualityComparer.Default.Equals(d.Target, sw.ExitLabel) && !(last && d == body[i])) return true;
                }
            }
            return false;
        }

        void Switch(ISwitchOperation sw, List<string> lines, int ind)
        {
            var vt = sw.Value.Type!;
            bool integral = IsIntegral(vt) || vt.TypeKind == TypeKind.Enum;
            bool wrap = HasInnerBreak(sw);
            var j = new Jump { Exit = sw.ExitLabel, IsSwitch = true, Wrapped = wrap };
            var v = Fresh("sv");
            lines.Add(Ind(ind) + "var " + v + " = " + X(sw.Value));
            int flagAt = lines.Count;
            int ci = ind;
            if (wrap) { lines.Add(Ind(ind) + "while True:"); ci = ind + 1; }
            jumps.Add(j);
            ISwitchCaseOperation? defCase = null;
            bool first = true;
            foreach (var c in sw.Cases)
            {
                if (c.Clauses.Any(cl => cl is IDefaultCaseClauseOperation)) { defCase = c; if (c.Clauses.Length == 1) continue; }
                var tests = new List<string>();
                foreach (var cl in c.Clauses)
                {
                    if (cl is IDefaultCaseClauseOperation) continue;
                    if (cl is not ISingleValueCaseClauseOperation sv) { Todo("case clause " + cl.CaseKind); return; }
                    if (integral)
                    {
                        if (!sv.Value.ConstantValue.HasValue) { Todo("case clause not constant"); return; }
                        tests.Add(v + " == " + Const(sv.Value.ConstantValue.Value, vt));
                    }
                    else if (vt.SpecialType == SpecialType.System_String) tests.Add("rt_str_eq(" + v + ", " + X(sv.Value) + ")");
                    else { Todo("switch on " + vt.ToDisplayString()); return; }
                }
                if (defCase == c) continue;     // a default with other labels: taken as the default
                lines.Add(Ind(ci) + (first ? "if " : "elif ") + string.Join(" or ", tests) + ":");
                first = false;
                CaseBody(c, lines, ci + 1);
            }
            if (defCase != null)
            {
                if (first) CaseBodyFlat(defCase, lines, ci);
                else { lines.Add(Ind(ci) + "else:"); CaseBody(defCase, lines, ci + 1); }
            }
            jumps.RemoveAt(jumps.Count - 1);
            if (wrap)
            {
                if (!(EndsInJump(lines) && LastAtLevel(lines, ci))) lines.Add(Ind(ci) + "break");
                if (j.Flag != null)
                {
                    lines.Insert(flagAt, Ind(ind) + "var " + j.Flag + " = False");
                    lines.Add(Ind(ind) + "if " + j.Flag + ":");
                    var k = jumps.FindLastIndex(x => SymbolEqualityComparer.Default.Equals(x.Cont, j.FlagTarget) || SymbolEqualityComparer.Default.Equals(x.Exit, j.FlagTarget));
                    if (k < 0) { Todo("switch flag target"); return; }
                    var tgt = jumps[k];
                    bool isCont = SymbolEqualityComparer.Default.Equals(tgt.Cont, j.FlagTarget);
                    // the jump goes on from here, through any wrapped switch outside this one
                    var fake = new List<string>();
                    BranchTo(tgt, isCont, k, fake, ind + 1);
                    lines.AddRange(fake);
                }
            }
        }

        void BranchTo(Jump tgt, bool isCont, int k, List<string> lines, int ind)
        {
            var p = Ind(ind);
            for (int i = jumps.Count - 1; i > k; i--)
            {
                var w = jumps[i];
                if (!w.Wrapped) continue;
                if (w.Flag == null) w.Flag = Fresh("jf");
                w.FlagTarget = isCont ? tgt.Cont : tgt.Exit;
                lines.Add(p + w.Flag + " = True");
                lines.Add(p + "break");
                return;
            }
            if (isCont) EmitContinue(tgt, lines, ind);
            else lines.Add(p + "break");
        }

        void CaseBody(ISwitchCaseOperation c, List<string> lines, int ind)
        {
            var body = c.Body.ToList();
            if (body.Count > 0 && body[^1] is IBranchOperation lb && lb.BranchKind == BranchKind.Break && jumps.Count > 0 && SymbolEqualityComparer.Default.Equals(lb.Target, jumps[^1].Exit))
            {
                body.RemoveAt(body.Count - 1);
                SubList(body, lines, ind);
                if (jumps[^1].Wrapped && !(EndsInJump(lines) && LastAtLevel(lines, ind))) lines.Add(Ind(ind) + "break");
                return;
            }
            SubList(body, lines, ind);
        }

        void CaseBodyFlat(ISwitchCaseOperation c, List<string> lines, int ind) => CaseBody(c, lines, ind);

        // -------------------------------------------------------------------------------------------- try regions
        void Try(ITryOperation t, List<string> lines, int ind)
        {
            Region(lines, ind, (ls, i) => SubList(t.Body.Operations, ls, i), t.Catches, t.Finally == null ? null : (ls, i) => SubList(t.Finally.Operations, ls, i));
        }

        void Region(List<string> lines, int ind, Action<List<string>, int> body, IEnumerable<ICatchClauseOperation> catches, Action<List<string>, int>? fin)
        {
            var p = Ind(ind);
            var n = Fresh("t");
            var cl = catches.ToList();
            var spv = "__sp" + n;
            if (cl.Count > 0) lines.Add(p + "var " + spv + " = rt_sp()");
            lines.Add(p + "try:");
            body(lines, ind + 1);
            if (cl.Count > 0)
            {
                var ev = "__e" + n;
                lines.Add(p + "except:");
                lines.Add(Ind(ind + 1) + "rt_set_sp(" + spv + ")");
                lines.Add(Ind(ind + 1) + "var " + ev + " = rt_exc_get()");
                bool first = true, all = false;
                foreach (var cc in cl)
                {
                    var et = cc.ExceptionType;
                    string? test;
                    if (et.SpecialType == SpecialType.System_Object || (et is INamedTypeSymbol en && IsSystem(en) && en.Name == "Exception")) test = null;
                    else if (et is INamedTypeSymbol nt) test = "__isA(" + ev + "[].tid, " + TargetTid(nt) + ")";
                    else { Todo("catch type"); return; }
                    if (cc.Filter != null) Todo("catch filter");
                    int hi = ind + 1;
                    if (test == null)
                    {
                        if (!first) { lines.Add(Ind(ind + 1) + "else:"); hi = ind + 2; }
                        all = true;
                    }
                    else { lines.Add(Ind(ind + 1) + (first ? "if " : "elif ") + test + ":"); hi = ind + 2; }
                    first = false;
                    if (cc.ExceptionDeclarationOrExpression is IVariableDeclaratorOperation vd)
                    {
                        var name = Declare(vd.Symbol, vd.Symbol.Name);
                        string val = ev;
                        if (et is INamedTypeSymbol ent && IsEngine(ent)) val = ev + ".cast[" + TypeIdent(ent) + "]()";
                        lines.Add(Ind(hi) + "var " + name + ": " + MojoType(vd.Symbol.Type) + " = " + val);
                    }
                    var saved = rethrowVar; rethrowVar = ev;
                    SubList(cc.Handler.Operations, lines, hi);
                    rethrowVar = saved;
                    if (all) break;
                }
                if (!all)
                {
                    lines.Add(Ind(ind + 1) + "else:");
                    lines.Add(Ind(ind + 2) + "raise rt_throw(" + ev + ")");
                }
            }
            if (fin != null)
            {
                lines.Add(p + "finally:");
                fin(lines, ind + 1);
            }
        }

        void UsingRest(IUsingDeclarationOperation ud, List<IOperation> rest, List<string> lines, int ind)
        {
            var decls = ud.DeclarationGroup.Declarations.SelectMany(d => d.Declarators).ToList();
            foreach (var d in ud.DeclarationGroup.Declarations)
                foreach (var v in d.Declarators) LocalDecl(v, d.Initializer, lines, ind);
            Region(lines, ind, (ls, i) => SubList(rest, ls, i), Array.Empty<ICatchClauseOperation>(), (ls, i) =>
            {
                foreach (var v in decls.AsEnumerable().Reverse())
                    ls.Add(Ind(i) + DisposeCall(VarRef(v.Symbol), v.Symbol.Type));
            });
        }

        string DisposeCall(string v, ITypeSymbol t)
        {
            if (t is INamedTypeSymbol nt && IsEngine(nt)) return TypeIdent(nt) + ".__dispose(" + v + ")";
            if (t.Name == "Defer") return v + "[].dispose_[" + DispatcherOf(new List<string>(), "NoneType") + "]()";
            return "rt_dispose(" + v + ")";
        }

        // -------------------------------------------------------------------------------------------- expression statements
        void StmtExpr(IOperation op, List<string> lines, int ind)
        {
            var p = Ind(ind);
            switch (op)
            {
                case ISimpleAssignmentOperation a:
                    {
                        if (a.Target is IDiscardOperation)
                        {
                            var inner = a.Value;
                            while (inner is IConversionOperation cv && (cv.IsImplicit || cv.Operand is ISimpleAssignmentOperation or ICompoundAssignmentOperation or IIncrementOrDecrementOperation)) inner = cv.Operand;
                            if (inner is ISimpleAssignmentOperation or ICompoundAssignmentOperation or IIncrementOrDecrementOperation or IInvocationOperation) { StmtExpr(inner, lines, ind); return; }
                            lines.Add(p + "_ = " + X(a.Value));
                            return;
                        }
                        if (a.IsRef) { lines.Add(p + RefRebind(a.Target) + " = " + Addr(a.Value)); return; }
                        if (IsCPtrElem(a.Target, out var cpe, out var cpi)) { lines.Add(p + cpe + ".set(Int(" + cpi + "), " + Value(a.Value, a.Target.Type) + ")"); return; }
                        var v = Value(a.Value, a.Target.Type);
                        lines.Add(p + Place(a.Target) + " = " + v);
                        return;
                    }
                case ICompoundAssignmentOperation ca: CompoundStmt(ca, lines, ind); return;
                case IIncrementOrDecrementOperation inc: IncStmt(inc, lines, ind); return;
                case IInvocationOperation iv:
                    {
                        var s = X(op);
                        if (s == "pass") return;
                        bool hasValue = !iv.TargetMethod.ReturnsVoid;
                        lines.Add(p + (hasValue ? "_ = " : "") + s);
                        return;
                    }
                case IObjectCreationOperation:
                    lines.Add(p + "_ = " + X(op));
                    return;
                case IConditionalAccessOperation ca when ca.Type == null || ca.Type.SpecialType == SpecialType.System_Void || ca.WhenNotNull is IInvocationOperation:
                    {
                        var o = Fresh("ca");
                        var recv = X(ca.Operation);
                        var ot = ca.Operation.Type!;
                        lines.Add(p + "var " + o + " = " + recv);
                        lines.Add(p + "if " + (ot.TypeKind == TypeKind.Delegate ? o + ".id != 0" : "not " + o + ".isnull()") + ":");
                        condAccess.Push(o);
                        int at = lines.Count;
                        StmtExpr(ca.WhenNotNull, lines, ind + 1);
                        if (lines.Count == at) lines.Add(Ind(ind + 1) + "pass");
                        condAccess.Pop();
                        return;
                    }
                case IDiscardOperation: return;
                default:
                    lines.Add(p + "_ = " + X(op));
                    return;
            }
        }

        string RefRebind(IOperation target)
        {
            if (target is ILocalReferenceOperation l && refVars.Contains(l.Local)) return names[l.Local];
            if (target is IParameterReferenceOperation pr && refVars.Contains(pr.Parameter)) return names[pr.Parameter];
            return Todo("ref reassignment of " + target.Kind);
        }

        void CompoundStmt(ICompoundAssignmentOperation ca, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var tt = ca.Target.Type!;
            if (IsCPtrElem(ca.Target, out var cpe, out var cpi))
            {
                var t0 = Fresh("cp"); var k0 = Fresh("ck");
                lines.Add(p + "var " + t0 + " = " + cpe);
                lines.Add(p + "var " + k0 + " = Int(" + cpi + ")");
                lines.Add(p + t0 + ".set(" + k0 + ", " + ArithOp(ca.OperatorKind, t0 + ".get(" + k0 + ")", Value(ca.Value, comp.GetSpecialType(SpecialType.System_Int32)), comp.GetSpecialType(SpecialType.System_Int32)) + ")");
                return;
            }
            var place = Place(ca.Target);
            string Cur(string cur)
            {
                if (ca.OperatorMethod != null) return UserBinary(ca.OperatorMethod, cur, X(ca.Value), tt, ca.Value.Type!);
                bool conv = ca.InConversion.Exists && !ca.InConversion.IsIdentity || ca.OutConversion.Exists && !ca.OutConversion.IsIdentity;
                var opT = ca.Value.Type!;
                return conv ? Conv(ArithOp(ca.OperatorKind, Conv(cur, tt, opT), X(ca.Value), opT), opT, tt) : ArithOp(ca.OperatorKind, cur, X(ca.Value), tt);
            }
            if (!SimplePlace(place))
            {
                var ptr = Fresh("cp");
                lines.Add(p + "var " + ptr + " = " + Addr(ca.Target));
                lines.Add(p + ptr + "[] = " + Cur(ptr + "[]"));
                return;
            }
            lines.Add(p + place + " = " + Cur(place));
        }

        static bool SimplePlace(string s) => System.Text.RegularExpressions.Regex.IsMatch(s, @"^[A-Za-z_][A-Za-z0-9_]*(\[\]|\.[A-Za-z_][A-Za-z0-9_]*|\(\))*$");

        void IncStmt(IIncrementOrDecrementOperation inc, List<string> lines, int ind)
        {
            var p = Ind(ind);
            bool up = inc.Kind == OperationKind.Increment;
            var t = inc.Target.Type!;
            if (IsCPtrElem(inc.Target, out var cpe, out var cpi))
            {
                var t0 = Fresh("cp"); var k0 = Fresh("ck");
                lines.Add(p + "var " + t0 + " = " + cpe);
                lines.Add(p + "var " + k0 + " = Int(" + cpi + ")");
                lines.Add(p + t0 + ".set(" + k0 + ", " + t0 + ".get(" + k0 + ")" + (up ? " + " : " - ") + "Int32(1))");
                return;
            }
            var place = Place(inc.Target);
            string Step(string cur) => inc.OperatorMethod != null ? RuntimeOpCall(inc.OperatorMethod, new[] { cur }) : StepValue(cur, t, up);
            if (!SimplePlace(place))
            {
                var ptr = Fresh("ip");
                lines.Add(p + "var " + ptr + " = " + Addr(inc.Target));
                lines.Add(p + ptr + "[] = " + Step(ptr + "[]"));
                return;
            }
            lines.Add(p + place + " = " + Step(place));
        }

        string StepValue(string cur, ITypeSymbol t, bool up)
        {
            if (IsFloat(t)) return "(" + cur + (up ? " + " : " - ") + MojoType(t) + "(1))";
            if (IsPtrType(t)) return cur + ".add(" + (up ? "1" : "-1") + ")";
            return "(" + cur + (up ? " + " : " - ") + MojoType(Under(t)) + "(1))";
        }

        static bool IsPtrType(ITypeSymbol t) => t is INamedTypeSymbol n && IsRuntime(n) && (n.Name == "CPtr" || StripArity(n.Name) == "Ptr");
    }
}
