// MojoExpr.cs - C# expressions (Roslyn IOperation trees) to Mojo expressions.
// Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Mojo
{
    static bool IsFloat(ITypeSymbol? t) => t != null && (t.SpecialType == SpecialType.System_Double || t.SpecialType == SpecialType.System_Single);
    static bool IsIntegral(ITypeSymbol? t) => t != null && t.SpecialType is SpecialType.System_Int32 or SpecialType.System_Int64 or SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_Int16 or SpecialType.System_UInt16 or SpecialType.System_SByte or SpecialType.System_Byte or SpecialType.System_Char;
    static bool IsNumeric(ITypeSymbol? t) => IsFloat(t) || IsIntegral(t);
    static bool IsUnsigned(ITypeSymbol? t) => t != null && t.SpecialType is SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_UInt16 or SpecialType.System_Byte or SpecialType.System_Char;
    static ITypeSymbol Under(ITypeSymbol t) => t.TypeKind == TypeKind.Enum ? ((INamedTypeSymbol)t).EnumUnderlyingType! : t;
    static string DT(ITypeSymbol t) => MojoType(Under(t)) switch
    {
        "Int8" => "DType.int8", "UInt8" => "DType.uint8", "Int16" => "DType.int16", "UInt16" => "DType.uint16", "Int32" => "DType.int32",
        "UInt32" => "DType.uint32", "Int64" => "DType.int64", "UInt64" => "DType.uint64", "Float32" => "DType.float32", "Float64" => "DType.float64",
        var x => Todo("dtype of " + x)
    };

    static string MojoStr(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (var ch in s)
        {
            int c = ch;
            if (c > 255) Todo("non-Latin-1 character in a string");
            if (c > 127) return "rt_hex(\"" + string.Concat(s.Select(x => ((int)x).ToString("x2"))) + "\")";
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c >= 32 && c < 127) sb.Append(ch);
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\t') sb.Append("\\t");
            else if (c == '\r') sb.Append("\\r");
            else sb.Append("\\x").Append(c.ToString("x2"));
        }
        return sb.Append('"').ToString();
    }

    public sealed partial class Fn
    {
        readonly Stack<string> condAccess = new();

        public string Value(IOperation op, ITypeSymbol? target)
        {
            var s = X(op);
            if (target != null && op.Type != null && !SymbolEqualityComparer.Default.Equals(op.Type, target))
                s = Conv(s, op.Type, target);
            return s;
        }

        string VarRef(ISymbol s)
        {
            if (captured.TryGetValue(s, out var f)) return "__c[]." + f + "[]";
            var n = names.TryGetValue(s, out var nn) ? nn : Todo("unknown variable " + s.Name);
            return refVars.Contains(s) || cells.Contains(s) || slots.Contains(s) ? n + "[]" : n;
        }

        string ThisRef() => inLambda ? (capturesThis ? "__c[].this" : Todo("this in a lambda that does not capture it")) : "this";

        public string X(IOperation op)
        {
            if (op.ConstantValue.HasValue && !(op is IFieldReferenceOperation fr0 && fr0.Field.ContainingType.TypeKind == TypeKind.Enum && IsEngine(fr0.Field.ContainingType)))
                return Const(op.ConstantValue.Value, op.Type);
            switch (op)
            {
                case IConversionOperation c: return Conversion(c);
                case ILocalReferenceOperation l: return VarRef(l.Local);
                case IParameterReferenceOperation pr: return VarRef(pr.Parameter);
                case IInstanceReferenceOperation ir:
                    if (ir.Type is INamedTypeSymbol bt && IsEngine(bt) && !SymbolEqualityComparer.Default.Equals(bt.OriginalDefinition, cls.OriginalDefinition) && DerivesOrSame(cls, bt))
                        return ThisRef() + ".cast[" + TypeIdent(bt) + "]()";
                    return ThisRef();
                case IFieldReferenceOperation f: return Field(f);
                case IPropertyReferenceOperation p: return Prop(p);
                case IArrayElementReferenceOperation ae:
                    if (ae.Indices.Length != 1) return Todo("multidimensional array element");
                    return X(ae.ArrayReference) + "[Int(" + X(ae.Indices[0]) + ")]";
                case IInvocationOperation inv: return Invoke(inv);
                case IObjectCreationOperation oc: return New(oc);
                case IArrayCreationOperation ac: return NewArray(ac);
                case IBinaryOperation b: return Binary(b);
                case IUnaryOperation u: return Unary(u);
                case IConditionalOperation c: return Ternary(c);
                case ISimpleAssignmentOperation a:
                    if (IsCPtrElem(a.Target, out var cpe, out var cpi)) return cpe + ".set_v(Int(" + cpi + "), " + Value(a.Value, a.Target.Type) + ")";
                    return "rt_asg(" + Addr(a.Target) + ", " + Value(a.Value, a.Target.Type) + ")";
                case ICompoundAssignmentOperation ca:
                    {
                        // the new value from the old one, through a helper that takes the place's address
                        var tt = ca.Target.Type!;
                        var h = Helper(new[] { "P[" + MojoType(tt) + "]", MojoType(ca.Value.Type!) }, MojoType(tt), args =>
                        {
                            string nv;
                            if (ca.OperatorMethod != null) nv = UserBinary(ca.OperatorMethod, "a0[]", "a1", tt, ca.Value.Type!);
                            else
                            {
                                bool conv = ca.InConversion.Exists && !ca.InConversion.IsIdentity || ca.OutConversion.Exists && !ca.OutConversion.IsIdentity;
                                var opT = ca.Value.Type!;
                                nv = conv ? Conv(ArithOp(ca.OperatorKind, Conv("a0[]", tt, opT), "a1", opT), opT, tt) : ArithOp(ca.OperatorKind, "a0[]", "a1", tt);
                            }
                            return new[] { "a0[] = " + nv, "return a0[]" };
                        });
                        return h + "(" + Addr(ca.Target) + ", " + X(ca.Value) + ")";
                    }
                case IIncrementOrDecrementOperation inc:
                    {
                        bool up = inc.Kind == OperationKind.Increment;
                        var t = inc.Target.Type!;
                        var nv = inc.OperatorMethod != null ? RuntimeOpCall(inc.OperatorMethod, new[] { "a0[]" }) : StepValue("a0[]", t, up);
                        var h = Helper(new[] { "P[" + MojoType(t) + "]" }, MojoType(t), args => inc.IsPostfix
                            ? new[] { "var o = a0[]", "a0[] = " + nv, "return o" }
                            : new[] { "a0[] = " + nv, "return a0[]" });
                        return h + "(" + Addr(inc.Target) + ")";
                    }
                case IConditionalAccessOperation ca: return CondAccess(ca);
                case IConditionalAccessInstanceOperation: return condAccess.Count > 0 ? condAccess.Peek() : Todo("conditional access instance");
                case IAnonymousFunctionOperation af: return Lambda(af, null);
                case IDelegateCreationOperation dc: return DelegateCreation(dc);
                case IDefaultValueOperation dv: return Zero(dv.Type!);
                case ILiteralOperation lit: return Const(lit.ConstantValue.Value, lit.Type);
                case IIsTypeOperation it: return IsType(it.ValueOperand, it.TypeOperand);
                case ICoalesceOperation co:
                    {
                        var v = X(co.Value);
                        if (!SimplePlace(v)) return Todo("coalesce of a computed value");
                        return "(" + v + " if not " + v + ".isnull() else " + Value(co.WhenNull, co.Type) + ")";
                    }
                case IParenthesizedOperation pp: return X(pp.Operand);
                case IDiscardOperation: return "_";
                case IThrowOperation: return Todo("throw expression");
            }
            return Todo("expression " + op.Kind);
        }

        /// <summary>A small top-level function for an expression Mojo cannot write inline (an assignment used as a
        /// value, an object initializer): its parameters are given, its body written from them.</summary>
        static string Helper(string[] ps, string ret, Func<string[], string[]> body)
        {
            var n = "__h" + (++helperCount);
            var f = new StringBuilder("def " + n + "(" + string.Join(", ", ps.Select((p, i) => "var a" + i + ": " + p)) + ") raises" + RetSuffix(ret) + ":\n");
            foreach (var l in body(ps.Select((p, i) => "a" + i).ToArray())) f.Append("    ").Append(l).Append('\n');
            funcs.Append(f).Append('\n');
            return n;
        }

        // ---- constants
        static string Const(object? v, ITypeSymbol? t)
        {
            if (v == null) return t != null ? Zero(t) : Todo("null without a type");
            switch (v)
            {
                case bool b: return b ? "True" : "False";
                case string s: return "CStr(" + MojoStr(s) + ")";
                case char ch: return "UInt16(" + (int)ch + ")";
                case double d: return t != null && t.SpecialType == SpecialType.System_Single ? FloatLit((float)d) : FloatLit(d);
                case float f: return t != null && t.SpecialType == SpecialType.System_Double ? FloatLit((double)f) : FloatLit(f);
            }
            var lit = IntLit(v);
            if (t == null) return lit;
            if (t.TypeKind == TypeKind.Enum)
            {
                var nt = (INamedTypeSymbol)t;
                if (IsEngine(nt))
                {
                    var mem = nt.GetMembers().OfType<IFieldSymbol>().FirstOrDefault(fm => fm.HasConstantValue && Equals(fm.ConstantValue, v));
                    if (mem != null) return TypeIdent(nt) + "__" + mem.Name.TrimStart('@');
                }
                return MojoType(t) + "(" + lit + ")";
            }
            if (IsFloat(t)) return t.SpecialType == SpecialType.System_Single ? FloatLit(Convert.ToSingle(v)) : FloatLit(Convert.ToDouble(v));
            return MojoType(t) + "(" + lit + ")";
        }

        /// <summary>A double literal: the shortest round-trip decimal (Mojo rounds a decimal literal once, as C# does;
        /// swmm5-ports lessons/43), or the bit pattern for NaN, the infinities and -0.0.</summary>
        static string FloatLit(double d)
        {
            long bits = BitConverter.DoubleToInt64Bits(d);
            if (double.IsNaN(d) || double.IsInfinity(d) || (d == 0 && bits != 0) || (d != 0 && Math.Abs(d) < 2.2250738585072014E-308))
                return "f64_bits(0x" + ((ulong)bits).ToString("x16") + ")";
            var s = d.ToString("R", CultureInfo.InvariantCulture);
            if (!s.Contains('.') && !s.Contains('E') && !s.Contains('e')) s += ".0";
            return "Float64(" + s.Replace("E", "e") + ")";
        }

        /// <summary>A float literal from its bits: Mojo's Float32(1e-45) is 0 (swmm5-ports lessons/43).</summary>
        static string FloatLit(float f) => "f32_bits(0x" + ((uint)BitConverter.SingleToInt32Bits(f)).ToString("x8") + ")";

        public static string Zero(ITypeSymbol t)
        {
            if (t.SpecialType == SpecialType.System_Boolean) return "False";
            if (IsNumeric(t) || t.TypeKind == TypeKind.Enum) return MojoType(t) + "(0)";
            return MojoType(t) + "()";
        }

        // ---- conversions
        string Conversion(IConversionOperation c)
        {
            var from = c.Operand.Type;
            var to = c.Type!;
            if (c.OperatorMethod != null) return RuntimeConvOp(c.OperatorMethod, c.Operand, to);
            if (c.Operand is IAnonymousFunctionOperation af) return Lambda(af, to);
            if (c.Operand is IDelegateCreationOperation dc0 && to.TypeKind == TypeKind.Delegate) return DelegateCreation(dc0, to);
            if (from == null)
            {
                if (c.Operand is ILiteralOperation || c.Operand is IDefaultValueOperation) return Zero(to);
                if (c.Operand is IDelegateCreationOperation dc) return DelegateCreation(dc, to);
                return X(c.Operand);
            }
            return Conv(X(c.Operand), from, to);
        }

        string Conv(string s, ITypeSymbol from, ITypeSymbol to)
        {
            if (SymbolEqualityComparer.Default.Equals(from, to)) return s;
            if (IsNumeric(to) || to.TypeKind == TypeKind.Enum)
            {
                var tu = Under(to);
                var tm = MojoType(tu);
                if (IsFloat(from) && IsIntegral(tu)) return "rt_d2" + tm.ToLowerInvariant() + "(" + (from.SpecialType == SpecialType.System_Single ? s + ".cast[DType.float64]()" : s) + ")";
                if ((IsFloat(from) || IsIntegral(from) || from.TypeKind == TypeKind.Enum) && (IsFloat(tu) || IsIntegral(tu)))
                {
                    if (MojoType(Under(from)) == tm) return s;
                    return s + ".cast[" + DT(tu) + "]()";
                }
                if (from.SpecialType == SpecialType.System_Object) return "rt_unbox[" + tm + "](" + s + ")";
                return Todo("conversion " + from.ToDisplayString() + " -> " + to.ToDisplayString());
            }
            if (from.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T || to.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return s;
            if (IsExceptionType(from) && IsExceptionType(to) && !IsEngine(from) && !IsEngine(to)) return s;
            if (to.SpecialType == SpecialType.System_Object || (to is INamedTypeSymbol tdi && IsSystem(tdi) && tdi.Name == "IDisposable"))
            {
                if (from.SpecialType == SpecialType.System_Object) return s;
                return "rt_box(" + s + ")";
            }
            if (from.SpecialType == SpecialType.System_Object) return "rt_unbox[" + MojoType(to) + "](" + s + ")";
            if (from is INamedTypeSymbol fn && to is INamedTypeSymbol tn)
            {
                if (IsEngine(fn) && IsEngine(tn) && (DerivesOrSame(fn, tn) || DerivesOrSame(tn, fn))) return s + ".cast[" + TypeIdent(tn) + "]()";
                if (IsEngine(fn) && IsExceptionType(tn) && !IsEngine(tn)) return ToRuntimeBase(s, fn);
                if (fn.TypeKind == TypeKind.Delegate && tn.TypeKind == TypeKind.Delegate) return s;
                if (IsRuntime(fn) && IsRuntime(tn) && MojoType(fn) == MojoType(tn)) return s;
                if (SymbolEqualityComparer.Default.Equals(fn.OriginalDefinition, tn.OriginalDefinition) && MojoType(fn) == MojoType(tn)) return s;
            }
            if (from is IArrayTypeSymbol && to is IArrayTypeSymbol && MojoType(from) == MojoType(to)) return s;
            return Todo("conversion " + from.ToDisplayString() + " -> " + to.ToDisplayString());
        }

        string RuntimeConvOp(IMethodSymbol op, IOperation operand, ITypeSymbol to)
        {
            var tn = StripArity(op.ContainingType.Name);
            var arg = X(operand);
            var pt = op.Parameters[0].Type;
            Use("conversion " + op.ToDisplayString(), "rt_conv");
            if (tn == "CPtr" && pt is INamedTypeSymbol pn && StripArity(pn.Name) == "Ptr") return "CPtr(" + arg + ")";
            if (tn == "Ptr" && pt is INamedTypeSymbol pn2 && StripArity(pn2.Name) == "Iter") return arg + ".ptr()";
            if (tn == "Str" && pt is INamedTypeSymbol pn3 && pn3.Name == "CPtr") return "Str.fromCPtr(" + arg + ")";
            return Todo("runtime conversion " + op.ToDisplayString());
        }

        // ---- fields and properties
        string Field(IFieldReferenceOperation f)
        {
            var fs = f.Field;
            if (fs.ContainingType.TypeKind == TypeKind.Enum)
            {
                if (IsEngine(fs.ContainingType)) return TypeIdent(fs.ContainingType) + "__" + fs.Name.TrimStart('@');
                return Const(fs.ConstantValue, fs.Type);
            }
            if (IsRuntime(fs))
            {
                if (fs.IsStatic || fs.IsConst)
                {
                    var n = RuntimeTypeName(fs.ContainingType) + ".s_" + Id(fs.Name) + "()";
                    Use("static field " + fs.OriginalDefinition.ToDisplayString(), n);
                    return n;
                }
                var it = f.Instance!.Type!;
                Use("field " + fs.OriginalDefinition.ToDisplayString(), Id(fs.Name));
                return X(f.Instance!) + (it.TypeKind == TypeKind.Struct ? "." : "[].") + Id(fs.Name);
            }
            if (fs.IsStatic || fs.IsConst) return StaticFieldName(fs);
            var r = X(f.Instance!);
            var rt0 = f.Instance!.Type as INamedTypeSymbol;
            var path = rt0 != null && IsEngine(rt0) ? BasePath(rt0, fs.ContainingType) : "";
            return r + "[]" + path + "." + FieldIdent(fs);
        }

        string Prop(IPropertyReferenceOperation p, bool addr = false)
        {
            var ps = p.Property;
            if (IsSystem(ps) && ps.Name == "Length") return "Int32(" + X(p.Instance!) + ".n)";
            if (!IsRuntime(ps)) return Todo((IsSystem(ps) ? "system" : "engine") + " property " + ps.ContainingType.Name + "." + ps.Name);
            var tn = StripArity(ps.ContainingType.Name);
            if (ps.IsStatic)
            {
                var n = RuntimeTypeName(ps.ContainingType) + ".p_" + ps.Name;
                Use("static property " + ps.ToDisplayString(), n);
                return n + "()";
            }
            var r = X(p.Instance!);
            var args = p.Arguments.Select(a => X(a.Value)).ToList();
            string place;
            if (tn == "Ptr" && ps.Name == "Deref") place = r + "[0]";
            else if ((tn == "Ptr" || tn == "CPtr") && ps.Name == "IsNull") return r + ".isnull()";
            else if (tn == "CPtr" && ps.IsIndexer) return addr ? Todo("address of a char") : r + ".get(Int(" + args[0] + "))";
            else if (tn == "Ptr" && ps.IsIndexer) place = r + "[Int(" + args[0] + ")]";
            else if (tn == "Vec" && ps.IsIndexer) place = r + "[].a[Int(" + args[0] + ")]";
            else if (tn == "Str" && ps.IsIndexer) place = r + "[].b[Int(" + args[0] + ")]";
            else
            {
                var mname = "p_" + (ps.IsIndexer ? "At" : ps.Name);
                Use("property " + ps.ContainingType.OriginalDefinition.ToDisplayString() + "." + ps.Name, mname + (ps.RefKind != RefKind.None ? " (pointer)" : ""));
                var recv = p.Instance!.Type!.TypeKind == TypeKind.Struct ? r : r + "[]";
                var call = recv + "." + mname + "(" + string.Join(", ", args) + ")";
                if (ps.RefKind == RefKind.None) return call;
                return addr ? call : call + "[]";
            }
            if (addr) return "rt_addr(" + place + ")";
            return place;
        }

        string Place(IOperation op) => X(op);

        /// <summary>An element of a char* (CPtr's int indexer: the byte read as a signed char, written as its low byte).</summary>
        bool IsCPtrElem(IOperation t, out string ptr, out string idx)
        {
            ptr = idx = "";
            if (t is IPropertyReferenceOperation p && p.Property.IsIndexer && p.Property.ContainingType.Name == "CPtr" && IsRuntime(p.Property))
            {
                ptr = X(p.Instance!);
                idx = X(p.Arguments[0].Value);
                return true;
            }
            return false;
        }

        /// <summary>A pointer to the location op names (a ref argument, a ref local, an address).</summary>
        public string Addr(IOperation op)
        {
            switch (op)
            {
                case ILocalReferenceOperation l: return AddrOf(l.Local);
                case IParameterReferenceOperation p: return AddrOf(p.Parameter);
                case IFieldReferenceOperation f: return "rt_addr(" + Field(f) + ")";
                case IArrayElementReferenceOperation ae: return X(ae.ArrayReference) + ".ptr(Int(" + X(ae.Indices[0]) + "))";
                case IPropertyReferenceOperation pr:
                    if (pr.Property.RefKind != RefKind.None || pr.Property.IsIndexer) return Prop(pr, true);
                    return Todo("address of a non-ref property " + pr.Property.Name);
                case IInvocationOperation inv when inv.TargetMethod.RefKind != RefKind.None:
                    return Invoke(inv, true);
                case IConditionalOperation c when c.IsRef:
                    return "(" + Addr(c.WhenTrue) + " if " + X(c.Condition) + " else " + Addr(c.WhenFalse!) + ")";
                case IConversionOperation cv when cv.Conversion.IsIdentity: return Addr(cv.Operand);
                case IParenthesizedOperation pp: return Addr(pp.Operand);
            }
            return Todo("address of " + op.Kind);
        }

        string AddrOf(ISymbol s)
        {
            if (captured.TryGetValue(s, out var f)) return "__c[]." + f;
            var n = names.TryGetValue(s, out var nn) ? nn : Todo("unknown variable " + s.Name);
            if (refVars.Contains(s) || cells.Contains(s) || slots.Contains(s)) return n;
            return Todo("address of a local kept in a register: " + s.Name);
        }

        // ---- calls
        List<string> ArgList(IMethodSymbol m, IEnumerable<IArgumentOperation> args, bool runtime)
        {
            var outv = new List<string>();
            foreach (var a in args.OrderBy(a => a.Parameter?.Ordinal ?? 0))
            {
                var prm = a.Parameter!;
                if (a.ArgumentKind == ArgumentKind.ParamArray)
                {
                    if (a.Value is IArrayCreationOperation ac && ac.Initializer != null)
                        outv.AddRange(ac.Initializer.ElementValues.Select(ParamsElem));
                    else outv.Add(Todo("params array passed as an array"));
                    continue;
                }
                if (prm.RefKind != RefKind.None) outv.Add(Addr(a.Value));
                else if (runtime && prm.OriginalDefinition.Type.SpecialType == SpecialType.System_Object && m.OriginalDefinition.Parameters[prm.Ordinal].Type.SpecialType == SpecialType.System_Object) outv.Add(Unboxed(a.Value));
                else outv.Add(Value(a.Value, prm.Type));
            }
            return outv;
        }

        string Args(IMethodSymbol m, IEnumerable<IArgumentOperation> args, bool runtime = false) => string.Join(", ", ArgList(m, args, runtime));

        string Unboxed(IOperation v)
        {
            while (v is IConversionOperation cv && cv.Type!.SpecialType == SpecialType.System_Object && cv.OperatorMethod == null) v = cv.Operand;
            if (v.Type == null) return "Obj()";
            return X(v);
        }

        /// <summary>An element of a params array (printf's and sscanf's arguments): the value as an rt.Arg; an sscanf
        /// target R.RefI(x => v = x) is the address of v.</summary>
        string ParamsElem(IOperation e)
        {
            while (e is IConversionOperation cv && cv.OperatorMethod == null && (cv.Type!.SpecialType == SpecialType.System_Object || cv.IsImplicit)) e = cv.Operand;
            if (e is IInvocationOperation iv && IsRuntime(iv.TargetMethod) && iv.TargetMethod.ContainingType.Name == "R" && iv.TargetMethod.Name.StartsWith("Ref") && iv.TargetMethod.Name.Length == 4)
            {
                var lam = iv.Arguments[0].Value;
                while (lam is IDelegateCreationOperation dc) lam = dc.Target;
                if (lam is IAnonymousFunctionOperation af)
                {
                    var ops = af.Body.Operations;
                    IOperation? st = ops.Length >= 1 ? ops[0] : null;
                    if (st is IExpressionStatementOperation es && es.Operation is ISimpleAssignmentOperation sa) return "A(" + Addr(sa.Target) + ")";
                    if (st is IReturnOperation ro && ro.ReturnedValue is ISimpleAssignmentOperation sa2) return "A(" + Addr(sa2.Target) + ")";
                }
                return Todo("sscanf target");
            }
            if (e is IFieldReferenceOperation fr && IsRuntime(fr.Field) && fr.Field.Name == "Slot") return "A_slot()";
            if (e.Type == null) return "A_null()";
            return "A(" + X(e) + ")";
        }

        string Invoke(IInvocationOperation inv, bool addr = false)
        {
            var m = inv.TargetMethod;
            string call;
            if (m.MethodKind == MethodKind.DelegateInvoke)
            {
                var a = Args(m, inv.Arguments);
                call = DispatcherFor(m) + "(" + X(inv.Instance!) + (a.Length > 0 ? ", " + a : "") + ")";
            }
            else if (IsRuntime(m) || IsSystem(m))
            {
                var special = SpecialRuntimeCall(inv);
                if (special != null) return special;
                call = RuntimeCall(m, inv.Instance, inv.Arguments);
            }
            else if (m.IsStatic)
                call = FuncName(m) + "(" + Args(m, inv.Arguments) + ")";
            else
            {
                var recvT = inv.Instance!.Type as INamedTypeSymbol;
                var r = X(inv.Instance!);
                var decl = m.ContainingType.OriginalDefinition;
                var a = Args(m, inv.Arguments);
                if (inv.IsVirtual && (m.IsVirtual || m.IsAbstract || m.IsOverride) && tids.ContainsKey(VRoot(m).ContainingType.OriginalDefinition))
                {
                    var root = VRoot(m).ContainingType.OriginalDefinition;
                    var rr = recvT != null && !SymbolEqualityComparer.Default.Equals(recvT.OriginalDefinition, root) ? r + ".cast[" + TypeIdent(root) + "]()" : r;
                    call = VDispatch(m) + "(" + rr + (a.Length > 0 ? ", " + a : "") + ")";
                }
                else
                {
                    var rr = recvT != null && IsEngine(recvT) && !SymbolEqualityComparer.Default.Equals(recvT.OriginalDefinition, decl) ? r + ".cast[" + TypeIdent(decl) + "]()" : r;
                    call = FuncName(m) + "(" + rr + (a.Length > 0 ? ", " + a : "") + ")";
                }
            }
            if (m.RefKind != RefKind.None) return addr ? call : call + "[]";
            return call;
        }

        static string DispatcherFor(IMethodSymbol invoke) =>
            DispatcherOf(invoke.Parameters.Select(ParamType).ToList(), RetType(invoke));

        string? SpecialRuntimeCall(IInvocationOperation inv)
        {
            var m = inv.TargetMethod;
            var tn = StripArity(m.ContainingType.Name);
            var args = inv.Arguments.OrderBy(a => a.Parameter!.Ordinal).ToList();
            if (tn == "Mv" && m.Name == "Back")
                return "rt_back(" + X(args[0].Value) + ", " + Addr(args[1].Value) + ", " + X(args[2].Value) + ")";
            if (tn == "R" && m.Name == "Back")
            {
                var inner = args[0].Value;
                while (inner is IConversionOperation cv) inner = cv.Operand;
                if (inner is not IInvocationOperation sc || sc.TargetMethod.Name != "sscanf") return Todo("R.Back of " + inner.Kind);
                var refs = args.Skip(1).Select(a => "A(" + Addr(a.Value) + ")").ToList();
                var s = Invoke(sc);
                int k = 0;
                while (s.Contains("A_slot()") && k < refs.Count) { var at = s.IndexOf("A_slot()"); s = s.Substring(0, at) + refs[k++] + s.Substring(at + 8); }
                return s;
            }
            if (tn == "R" && m.Name == "Lit" && args.Count == 1)
            {
                var a = args[0].Value;
                if (a.ConstantValue.HasValue && a.ConstantValue.Value is string str) return "rt_lit(" + MojoStr(str) + ")";
                return "rt_lit(" + X(a) + ")";
            }
            if (tn == "R" && m.Name == "LitN" && args.Count == 2)
            {
                var a = args[0].Value;
                if (a.ConstantValue.HasValue && a.ConstantValue.Value is string str) return "rt_litn(" + MojoStr(str) + ", Int(" + X(args[1].Value) + "))";
                return Todo("R.LitN of a computed string");
            }
            if (tn == "Std" && m.Name == "Nop") return "Int32(0)";
            if (tn == "Dbg" && m.Name == "Caught") return "pass";
            if (tn == "Box" && m.Name == "Of")
            {
                var lam = args[0].Value;
                while (lam is IDelegateCreationOperation dc) lam = dc.Target;
                while (lam is IConversionOperation cv2) lam = cv2.Operand;
                if (lam is IAnonymousFunctionOperation af && af.Body.Operations.Length == 1 && af.Body.Operations[0] is IReturnOperation ro && ro.ReturnedValue != null)
                    return "Box[" + MojoType(((INamedTypeSymbol)m.ContainingType).TypeArguments[0]) + "].of(" + Addr(ro.ReturnedValue) + ")";
                return Todo("Box.Of of " + lam.Kind);
            }
            if ((tn == "Dtor" && m.Name == "Run") || (tn == "Mv" && m.Name == "Delete"))
            {
                var v = args[0].Value;
                while (v is IConversionOperation cv && cv.Type!.SpecialType == SpecialType.System_Object) v = cv.Operand;
                if (v.Type is INamedTypeSymbol et && IsEngine(et))
                {
                    if (!NeedsDisposeDispatch(et)) return "pass";
                    return TypeIdent(et) + ".__dispose(" + X(v) + ")";
                }
                if (v.Type == null) return "pass";
                if (v.Type.Name == "Defer") return X(v) + "[].dispose_[" + DispatcherOf(new List<string>(), "NoneType") + "]()";
                return "rt_dispose(" + X(v) + ")";
            }
            return null;
        }

        string RuntimeCall(IMethodSymbol m, IOperation? inst, IEnumerable<IArgumentOperation> argOps)
        {
            var t = m.ContainingType;
            if (IsSystem(m)) return SystemCall(m, inst, argOps);
            if (m.Name == "Clone" && !m.IsStatic && t.TypeKind == TypeKind.Struct && m.Parameters.Length == 0) return X(inst!);
            var name = Id(m.Name);
            var cparams = new List<string>();
            if (m.IsGenericMethod) cparams.AddRange(m.TypeArguments.Select(MojoType));
            // a delegate argument: its dispatcher goes to the runtime as a compile-time parameter
            foreach (var p in m.OriginalDefinition.Parameters)
                if (p.Type.TypeKind == TypeKind.Delegate || (p.Type is ITypeParameterSymbol == false && p.Type.Name is "Func" or "Action"))
                {
                    var actual = m.Parameters[p.Ordinal].Type as INamedTypeSymbol;
                    if (actual?.DelegateInvokeMethod != null) cparams.Add(DispatcherFor(actual.DelegateInvokeMethod));
                }
            var args = ArgList(m, argOps, true);
            var all = string.Join(", ", args);
            var cp = cparams.Count > 0 ? "[" + string.Join(", ", cparams) + "]" : "";
            if (m.IsStatic)
            {
                var n = RuntimeTypeName(t) + "." + name;
                Use("static " + m.OriginalDefinition.ToDisplayString(), StripArity(t.Name) + "." + name);
                return n + cp + "(" + all + ")";
            }
            Use("method " + m.OriginalDefinition.ToDisplayString(), name);
            var r = X(inst!);
            var recv = inst!.Type!.TypeKind == TypeKind.Struct ? r : r + "[]";
            return recv + "." + name + cp + "(" + all + ")";
        }

        string SystemCall(IMethodSymbol m, IOperation? inst, IEnumerable<IArgumentOperation> argOps)
        {
            var t = m.ContainingType.Name;
            var args = ArgList(m, argOps, false);
            var a = string.Join(", ", args);
            if (t == "Math" || t == "MathF")
            {
                Use("System.Math." + m.Name + "(" + string.Join(",", m.Parameters.Select(p => p.Type.Name)) + ")", "Math." + m.Name);
                return "Math." + m.Name + "(" + a + ")";
            }
            if (t == "Object" && m.Name == "ReferenceEquals") return "(" + args[0] + " == " + args[1] + ")";
            if (t == "Double" && m.Name is "IsNaN" or "IsFinite" or "IsInfinity" or "IsPositiveInfinity" or "IsNegativeInfinity" or "IsNegative")
                return "Dbl." + m.Name + "(" + a + ")";
            if (t == "BitConverter") { Use("System.BitConverter." + m.Name, "BitConverter." + m.Name); return "BitConverter." + m.Name + "(" + a + ")"; }
            if (t == "File" && m.Name == "Exists") return "File.Exists(" + a + ")";
            if (t == "Array" && m.Name == "Fill") return "rt_array_fill(" + a + ")";
            return Todo("system call " + m.ContainingType.Name + "." + m.Name);
        }

        /// <summary>A lambda `() => Arr.Make&lt;T&gt;(n)` (how a container makes an element that is a C array): n.</summary>
        static int? MakeLen(IOperation o)
        {
            while (o is IConversionOperation cv) o = cv.Operand;
            while (o is IDelegateCreationOperation dc) o = dc.Target;
            if (o is IAnonymousFunctionOperation af && af.Body.Operations.Length == 1 && af.Body.Operations[0] is IReturnOperation ro &&
                ro.ReturnedValue is IInvocationOperation iv && iv.TargetMethod.Name == "Make" && iv.TargetMethod.ContainingType.Name == "Arr" &&
                iv.Arguments.Length == 1 && iv.Arguments[0].Value.ConstantValue.HasValue)
                return Convert.ToInt32(iv.Arguments[0].Value.ConstantValue.Value);
            return null;
        }

        /// <summary>A lambda `() => Arr.MakeWith&lt;T[]&gt;(n, () => Arr.Make&lt;T&gt;(m))` (a C array of arrays): n and m.</summary>
        static (int, int)? MakeLen2(IOperation o)
        {
            while (o is IConversionOperation cv) o = cv.Operand;
            while (o is IDelegateCreationOperation dc) o = dc.Target;
            if (o is IAnonymousFunctionOperation af && af.Body.Operations.Length == 1 && af.Body.Operations[0] is IReturnOperation ro &&
                ro.ReturnedValue is IInvocationOperation iv && iv.TargetMethod.Name == "MakeWith" && iv.Arguments.Length == 2 &&
                iv.Arguments[0].Value.ConstantValue.HasValue && MakeLen(iv.Arguments[1].Value) is int m)
                return (Convert.ToInt32(iv.Arguments[0].Value.ConstantValue.Value), m);
            return null;
        }

        string New(IObjectCreationOperation oc)
        {
            var t = (INamedTypeSymbol)oc.Type!;
            var c = oc.Constructor!;
            string e;
            if (t.TypeKind == TypeKind.Delegate) return Todo("delegate construction");
            if (IsEngine(t))
            {
                var tn = TypeIdent(t);
                if (c.Parameters.Length == 1 && c.Parameters[0].Type.Name == "Raw") e = tn + "__raw()";
                else if (c.Parameters.Length == 0) e = tn + "__new()";
                else return Todo("engine constructor with arguments");
            }
            else if (IsRuntime(t))
            {
                var tn = StripArity(t.Name);
                var args = oc.Arguments.OrderBy(a => a.Parameter!.Ordinal).ToList();
                var rtn = RuntimeTypeName(t);
                if (tn == "Ptr" && args.Count == 2 && args[1].Value.Type?.TypeKind != TypeKind.Delegate && args[0].Value.Type?.SpecialType != SpecialType.System_Object)
                    e = rtn + "(" + X(args[0].Value) + ", Int(" + X(args[1].Value) + "))";
                else if (tn == "Ptr" && args.Count == 2)
                    e = FieldPtr(args[0].Value, args[1].Value, t.TypeArguments[0]);
                else if (IsExceptionType(t))
                {
                    var k = runtimeExcKinds.TryGetValue(tn, out var kk) ? kk : Todo("exception kind " + tn) is var _ ? 0 : 0;
                    var msg = args.Count > 0 ? args[0].Value : null;
                    if (msg == null) e = "rt_exc_make(" + k + ", Ref[Str]())";
                    else e = "rt_exc_make(" + k + ", " + Value(msg, args[0].Parameter!.Type) + ")";
                }
                else if (tn == "Defer")
                    e = "Defer.new_(" + X(args[0].Value) + ")";
                else
                {
                    // a delegate argument that makes a C array element: its length
                    var parts = new List<string>();
                    string sfx = "";
                    foreach (var a in args)
                    {
                        if (a.Parameter!.Type.TypeKind == TypeKind.Delegate)
                        {
                            if (a.Value.ConstantValue.HasValue && a.Value.ConstantValue.Value == null) continue;
                            var nmk = MakeLen(a.Value);
                            if (nmk != null) { parts.Add("mk=" + nmk.Value); continue; }
                            var mk2 = MakeLen2(a.Value);
                            if (mk2 == null) return Todo("runtime constructor with a delegate " + t.Name);
                            parts.Add("mk=" + mk2.Value.Item1); parts.Add("mk2=" + mk2.Value.Item2);
                            continue;
                        }
                        parts.Add(a.Parameter.RefKind != RefKind.None ? Addr(a.Value) : a.Parameter.Type.SpecialType == SpecialType.System_Object ? Unboxed(a.Value) : Value(a.Value, a.Parameter.Type));
                    }
                    var ctorArgs = args.Where(a => a.ArgumentKind == ArgumentKind.ParamArray).ToList();
                    if (ctorArgs.Count > 0) { parts.Clear(); parts.AddRange(ArgList(c, oc.Arguments, true)); }
                    // the four stream classes are two Mojo types: the constructor names the class
                    if (tn is "IStringStream" or "IFStream" or "OStringStream" or "OFStream") sfx = tn;
                    Use("new " + c.OriginalDefinition.ToDisplayString(), "new_" + sfx);
                    e = rtn + ".new_" + sfx + "(" + string.Join(", ", parts) + ")";
                }
            }
            else if (IsSystem(t))
            {
                if (IsExceptionType(t))
                {
                    var k = runtimeExcKinds.TryGetValue(t.Name, out var kk) ? kk : 100;
                    e = "rt_exc_make(" + k + ", " + (oc.Arguments.Length > 0 ? "Str.fromCStr(" + X(oc.Arguments[0].Value) + ")" : "Ref[Str]()") + ")";
                }
                else return Todo("new " + t.ToDisplayString());
            }
            else return Todo("new " + t.ToDisplayString());
            if (oc.Initializer == null || oc.Initializer.Initializers.Length == 0) return e;
            // new X() { a = 1, b = 2 }: a helper that makes the object and sets the fields from its arguments
            var vals = new List<string>(); var types = new List<string>(); var sets = new List<string>();
            int i = 0;
            foreach (var init in oc.Initializer.Initializers)
            {
                if (init is ISimpleAssignmentOperation a && a.Target is IFieldReferenceOperation f)
                {
                    vals.Add(Value(a.Value, a.Target.Type));
                    types.Add(MojoType(a.Target.Type!));
                    var fname = IsRuntime(f.Field) ? Id(f.Field.Name) : FieldIdent(f.Field);
                    var path = IsEngine(t) ? BasePath(t, f.Field.ContainingType) : "";
                    sets.Add("o" + (t.TypeKind == TypeKind.Struct ? "" : "[]") + path + "." + fname + " = a" + i);
                    i++;
                }
                else Todo("object initializer " + init.Kind);
            }
            var obj = e;
            var h = Helper(types.ToArray(), MojoType(t), _ => new[] { "var o = " + obj }.Concat(sets).Append("return o").ToArray());
            return h + "(" + string.Join(", ", vals) + ")";
        }

        /// <summary>new Ptr&lt;T&gt;(obj, (object o) =&gt; ref ((C)o).f): the address of that field of obj.</summary>
        string FieldPtr(IOperation obj, IOperation getter, ITypeSymbol elem)
        {
            var lam = getter;
            while (lam is IDelegateCreationOperation dc) lam = dc.Target;
            while (lam is IConversionOperation cv) lam = cv.Operand;
            if (lam is not IAnonymousFunctionOperation af || af.Body.Operations.Length != 1 || af.Body.Operations[0] is not IReturnOperation ro || ro.ReturnedValue == null)
                return Todo("field pointer of " + lam.Kind);
            var prm = af.Symbol.Parameters[0];
            while (obj is IConversionOperation oc0 && oc0.Type!.SpecialType == SpecialType.System_Object) obj = oc0.Operand;
            var ot = obj.Type;
            string objv = ot == null ? "Obj()" : X(obj);
            if (!SimplePlace(objv) && objv != "Obj()") return Todo("field pointer of a computed object");
            if (ot != null && ot.SpecialType != SpecialType.System_Object) objv = Conv(objv, ot, comp.GetSpecialType(SpecialType.System_Object));
            names[prm] = objv;
            return "Ptr[" + MojoType(elem) + "](" + Addr(ro.ReturnedValue) + ")";
        }

        string NewArray(IArrayCreationOperation ac)
        {
            var at = (IArrayTypeSymbol)ac.Type!;
            var et = MojoType(at.ElementType);
            // a long initializer of zeros (C++ `char buf[65536] = {}`) is a zeroed array: a call of `of` with tens of
            // thousands of arguments takes Mojo's compiler hours (lessons/75)
            if (ac.Initializer != null && ac.Initializer.ElementValues.Length > 16 && ac.Initializer.ElementValues.All(ZeroConst))
                return "Ary[" + et + "].make(Int(" + ac.Initializer.ElementValues.Length + "))";
            if (ac.Initializer != null)
                return "Ary[" + et + "].of(" + string.Join(", ", ac.Initializer.ElementValues.Select(v => Value(v, at.ElementType))) + ")";
            return "Ary[" + et + "].make(Int(" + X(ac.DimensionSizes[0]) + "))";
        }

        static bool ZeroConst(IOperation v)
        {
            if (!v.ConstantValue.HasValue) return false;
            var c = v.ConstantValue.Value;
            switch (c)
            {
                case null: return false;
                case bool b: return !b;
                case double d: return BitConverter.DoubleToInt64Bits(d) == 0;
                case float f: return BitConverter.SingleToInt32Bits(f) == 0;
                case char ch: return ch == 0;
                case string: return false;
                default: return Convert.ToDecimal(c) == 0m;
            }
        }

        // ---- operators
        string ArithOp(BinaryOperatorKind k, string l, string r, ITypeSymbol t)
        {
            t = Under(t);
            bool fl = IsFloat(t);
            bool un = IsUnsigned(t);
            bool bo = t.SpecialType == SpecialType.System_Boolean;
            switch (k)
            {
                case BinaryOperatorKind.Add: return "(" + l + " + " + r + ")";
                case BinaryOperatorKind.Subtract: return "(" + l + " - " + r + ")";
                case BinaryOperatorKind.Multiply: return "(" + l + " * " + r + ")";
                case BinaryOperatorKind.Divide: return fl ? "(" + l + " / " + r + ")" : un ? "(" + l + " // " + r + ")" : "rt_idiv(" + l + ", " + r + ")";
                case BinaryOperatorKind.Remainder: return fl ? "LibM.fmod(" + l + ", " + r + ")" : un ? "(" + l + " % " + r + ")" : "rt_irem(" + l + ", " + r + ")";
                case BinaryOperatorKind.LeftShift: return "rt_shl(" + l + ", " + r + ")";
                case BinaryOperatorKind.RightShift: return "rt_shr(" + l + ", " + r + ")";
                case BinaryOperatorKind.UnsignedRightShift: return "rt_ushr(" + l + ", " + r + ")";
                case BinaryOperatorKind.And: return bo ? "rt_band(" + l + ", " + r + ")" : "(" + l + " & " + r + ")";
                case BinaryOperatorKind.Or: return bo ? "rt_bor(" + l + ", " + r + ")" : "(" + l + " | " + r + ")";
                case BinaryOperatorKind.ExclusiveOr: return bo ? "(" + l + " != " + r + ")" : "(" + l + " ^ " + r + ")";
                case BinaryOperatorKind.ConditionalAnd: return "(" + l + " and " + r + ")";
                case BinaryOperatorKind.ConditionalOr: return "(" + l + " or " + r + ")";
                case BinaryOperatorKind.Equals: return "(" + l + " == " + r + ")";
                case BinaryOperatorKind.NotEquals: return "(" + l + " != " + r + ")";
                case BinaryOperatorKind.LessThan: return "(" + l + " < " + r + ")";
                case BinaryOperatorKind.LessThanOrEqual: return "(" + l + " <= " + r + ")";
                case BinaryOperatorKind.GreaterThan: return "(" + l + " > " + r + ")";
                case BinaryOperatorKind.GreaterThanOrEqual: return "(" + l + " >= " + r + ")";
            }
            return Todo("operator " + k);
        }

        string Binary(IBinaryOperation b)
        {
            if (b.OperatorMethod != null) return UserBinary(b.OperatorMethod, X(b.LeftOperand), X(b.RightOperand), b.LeftOperand.Type!, b.RightOperand.Type!);
            var lt = b.LeftOperand.Type;
            var rtp = b.RightOperand.Type;
            if (b.OperatorKind is BinaryOperatorKind.Equals or BinaryOperatorKind.NotEquals)
            {
                var op = b.OperatorKind == BinaryOperatorKind.Equals ? " == " : " != ";
                if (lt != null && lt.TypeKind == TypeKind.Delegate && IsNullConst(b.RightOperand)) return "(" + X(b.LeftOperand) + ".id" + op + "0)";
                if (rtp != null && rtp.TypeKind == TypeKind.Delegate && IsNullConst(b.LeftOperand)) return "(" + X(b.RightOperand) + ".id" + op + "0)";
                if (lt != null && lt.SpecialType == SpecialType.System_String) return Todo("string comparison");
            }
            return ArithOp(b.OperatorKind, X(b.LeftOperand), X(b.RightOperand), lt ?? b.Type!);
        }

        static bool IsNullConst(IOperation o)
        {
            while (o is IConversionOperation c) o = c.Operand;
            return o.ConstantValue.HasValue && o.ConstantValue.Value == null;
        }

        string UserBinary(IMethodSymbol op, string l, string r, ITypeSymbol lt, ITypeSymbol rtp)
        {
            if (!IsRuntime(op)) return Todo("engine operator " + op.Name);
            var tn = StripArity(op.ContainingType.Name);
            if (tn == "CPtr" || tn == "Ptr")
            {
                bool rIsPtr = IsPtrType(op.Parameters[1].Type);
                switch (op.Name)
                {
                    case "op_Addition": return l + ".add(Int(" + r + "))";
                    case "op_Subtraction": return rIsPtr ? l + ".diff(" + r + ")" : l + ".add(-Int(" + r + "))";
                    case "op_Equality": return "(" + l + " == " + r + ")";
                    case "op_Inequality": return "(" + l + " != " + r + ")";
                    case "op_LessThan": return "(" + l + ".addr() < " + r + ".addr())";
                    case "op_GreaterThan": return "(" + l + ".addr() > " + r + ".addr())";
                    case "op_LessThanOrEqual": return "(" + l + ".addr() <= " + r + ".addr())";
                    case "op_GreaterThanOrEqual": return "(" + l + ".addr() >= " + r + ".addr())";
                }
                return Todo("pointer operator " + op.Name);
            }
            return RuntimeOpCall(op, new[] { l, r });
        }

        string RuntimeOpCall(IMethodSymbol op, string[] args)
        {
            var t = op.ContainingType;
            var tn = StripArity(t.Name);
            if ((tn == "CPtr" || tn == "Ptr") && args.Length == 1)
            {
                if (op.Name == "op_Increment") return args[0] + ".add(1)";
                if (op.Name == "op_Decrement") return args[0] + ".add(-1)";
            }
            var opn = op.Name switch
            {
                "op_Addition" => "add", "op_Subtraction" => "sub", "op_Equality" => "eq", "op_Inequality" => "ne",
                "op_LessThan" => "lt", "op_GreaterThan" => "gt", "op_LessThanOrEqual" => "le", "op_GreaterThanOrEqual" => "ge",
                "op_Multiply" => "mul", "op_Division" => "div", "op_Increment" => "inc", "op_Decrement" => "dec",
                _ => Todo("operator " + op.Name)
            };
            var n = RuntimeTypeName(t) + ".op_" + opn;
            Use("operator " + op.OriginalDefinition.ToDisplayString(), "op_" + opn);
            return n + "(" + string.Join(", ", args) + ")";
        }

        string Unary(IUnaryOperation u)
        {
            if (u.OperatorMethod != null) return Todo("user unary operator");
            var o = X(u.Operand);
            return u.OperatorKind switch
            {
                UnaryOperatorKind.Minus => "(-" + o + ")",
                UnaryOperatorKind.Plus => o,
                UnaryOperatorKind.Not => "(not " + o + ")",
                UnaryOperatorKind.BitwiseNegation => "(~" + o + ")",
                _ => Todo("unary " + u.OperatorKind)
            };
        }

        string Ternary(IConditionalOperation c)
        {
            var cond = X(c.Condition);
            var t = c.Type!;
            return "(" + Value(c.WhenTrue, t) + " if " + cond + " else " + Value(c.WhenFalse!, t) + ")";
        }

        string CondAccess(IConditionalAccessOperation ca)
        {
            var t = ca.Type!;
            var recv = X(ca.Operation);
            var ot = ca.Operation.Type!;
            if (ot.TypeKind == TypeKind.Delegate) return Todo("conditional access on a delegate value");
            if (!SimplePlace(recv)) return Todo("conditional access on a computed value");
            condAccess.Push(recv);
            var w = Value(ca.WhenNotNull, t);
            condAccess.Pop();
            return "(" + w + " if not " + recv + ".isnull() else " + Zero(t) + ")";
        }

        string IsType(IOperation v, ITypeSymbol t)
        {
            var from = v.Type!;
            if (t is INamedTypeSymbol nt && IsEngine(nt) && from is INamedTypeSymbol fn && IsEngine(fn))
            {
                var x = X(v);
                if (!SimplePlace(x)) return Todo("is on a computed value");
                return "(not " + x + ".isnull() and __isA(" + x + "[]" + TidPath(fn) + ", " + Tid(nt) + "))";
            }
            return Todo("is " + t.ToDisplayString() + " on " + from.ToDisplayString());
        }

        // ---- lambdas: a function with a context struct holding pointers to the captured variables' cells
        string Lambda(IAnonymousFunctionOperation af, ITypeSymbol? target)
        {
            var m = af.Symbol;
            var n = ++lambdaCount;
            var fname = "__lam" + n;
            var caps = CapturedBy(af, out var usesThis);
            usesThis = usesThis && !(method?.IsStatic ?? true) || (usesThis && inLambda && capturesThis);
            var sub = new Fn(this, m) { capturesThis = usesThis };
            var ctxType = "__Ctx" + n;
            var fields = new List<string>();
            var mkps = new List<string>();
            var mkargs = new List<string>();
            if (usesThis)
            {
                fields.Add("this: Ref[" + TypeIdent(cls) + "]");
                mkps.Add("this: Ref[" + TypeIdent(cls) + "]");
                mkargs.Add(ThisRef());
            }
            int k = 0;
            foreach (var s in caps)
            {
                var fn = "c" + (k++) + "_" + s.Name.TrimStart('@');
                var st = s is ILocalSymbol ls ? ls.Type : ((IParameterSymbol)s).Type;
                fields.Add(fn + ": P[" + MojoType(st) + "]");
                mkps.Add(fn + ": P[" + MojoType(st) + "]");
                mkargs.Add(AddrOf(s));
                sub.captured[s] = fn;
            }
            var body = sub.Body(af.Body, m.Parameters, false);
            var ps = new List<string> { "__ctx: VP" };
            foreach (var p in m.Parameters) ps.Add(sub.ParamDecl(p));
            var f = new StringBuilder();
            if (fields.Count > 0)
            {
                f.Append("struct ").Append(ctxType).Append("(Movable):\n");
                foreach (var fl in fields) f.Append("    var ").Append(fl).Append('\n');
                f.Append('\n');
                f.Append("def __mk").Append(n).Append('(').Append(string.Join(", ", mkps)).Append(") -> VP:\n    var c = gc_new[").Append(ctxType).Append("]()\n");
                foreach (var fl in fields) { var fn0 = fl.Substring(0, fl.IndexOf(':')); f.Append("    c[].").Append(fn0).Append(" = ").Append(fn0).Append('\n'); }
                f.Append("    return c.unsafe_bitcast[NoneType]()\n\n");
            }
            f.Append("def ").Append(fname).Append('(').Append(string.Join(", ", ps)).Append(") raises").Append(RetSuffix(RetType(m))).Append(":\n");
            if (fields.Count > 0) f.Append("    var __c = __ctx.unsafe_bitcast[").Append(ctxType).Append("]()\n");
            f.Append(body).Append('\n');
            funcs.Append(f);
            var inv = target is INamedTypeSymbol tn && tn.DelegateInvokeMethod != null ? tn.DelegateInvokeMethod : m;
            var disp = DispatcherOf(inv.Parameters.Select(ParamType).ToList(), RetType(inv));
            var id = AddTarget(disp, fname);
            var ctx = fields.Count == 0 ? "VP_null()" : "__mk" + n + "(" + string.Join(", ", mkargs) + ")";
            return "Dlg(" + ctx + ", " + id + ")";
        }

        string DelegateCreation(IDelegateCreationOperation dc, ITypeSymbol? target = null)
        {
            var t = target ?? dc.Type!;
            if (dc.Target is IAnonymousFunctionOperation af) return Lambda(af, t);
            if (dc.Target is IMethodReferenceOperation mr)
            {
                var m = mr.Method;
                var inv = ((INamedTypeSymbol)t).DelegateInvokeMethod!;
                var n = ++thunkCount;
                var fname = "__thunk" + n;
                var ps = new List<string> { "__ctx: VP" };
                var args = new List<string>();
                int i = 0;
                foreach (var p in inv.Parameters) { ps.Add("a" + i + ": " + ParamType(p)); args.Add("a" + i); i++; }
                var f = new StringBuilder("def " + fname + "(" + string.Join(", ", ps) + ") raises" + RetSuffix(RetType(inv)) + ":\n");
                string ctx;
                if (IsRuntime(m) || IsSystem(m)) return Todo("delegate of a runtime method " + m.Name);
                if (m.IsStatic) { f.Append("    return ").Append(FuncName(m)).Append('(').Append(string.Join(", ", args)).Append(")\n"); ctx = "VP_null()"; }
                else
                {
                    var ct = TypeIdent(m.ContainingType);
                    f.Append("    return ").Append(FuncName(m)).Append("(Ref[").Append(ct).Append("](__ctx.unsafe_bitcast[").Append(ct).Append("]())").Append(args.Count > 0 ? ", " + string.Join(", ", args) : "").Append(")\n");
                    var recvT = mr.Instance!.Type as INamedTypeSymbol;
                    var r = X(mr.Instance!);
                    if (recvT != null && !SymbolEqualityComparer.Default.Equals(recvT.OriginalDefinition, m.ContainingType.OriginalDefinition)) r = r + ".cast[" + ct + "]()";
                    ctx = r + ".vp()";
                }
                funcs.Append(f).Append('\n');
                var disp = DispatcherOf(inv.Parameters.Select(ParamType).ToList(), RetType(inv));
                var id = AddTarget(disp, fname);
                return "Dlg(" + ctx + ", " + id + ")";
            }
            return Todo("delegate creation " + dc.Target.Kind);
        }
    }
}
