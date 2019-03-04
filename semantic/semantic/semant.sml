structure Semant = 
struct
  structure A = Absyn;
  structure S = Symbol;

  type venv = Env.enventry S.table
  type tenv = Types.ty S.table

  type expty = { exp: Translate.exp, ty: Types.ty }

  val teq = Types.eq

  val PLACEHOLDER: expty = { exp = (), ty = Types.UNIT }

  fun actualType(t: Types.ty, pos: int): Types.ty Log.log =
    let 
      fun member(nil, elm) = false
        | member(x::rst, elm) = (S.id x) = (S.id elm) orelse member(rst, elm)
      fun join(lst) = 
        String.concatWith "=" (map (fn s => S.name s) lst)
           
      fun helper(Types.NAME(s, tref), visited) = 
        if member(visited, s)
        then Log.failure(Types.BOT, pos, 
               ("Could not resolve types " ^ (join visited) ^ 
               " due to cyclic definition."))
        else
          (case !tref of
            SOME(typ) => helper(typ, s :: visited)
          | NONE => Log.failure(Types.BOT, pos, ("Could not resolve type " ^ (S.name s))))
        | helper(t, _) = Log.success(t)
    in
      helper(t, [])
    end


  fun typeToString(pos: int)(ty: Types.ty): string Log.log =
    case ty of
      Types.NIL => Log.success("Nil")
    | Types.INT => Log.success("Int")
    | Types.STRING => Log.success("String")
    | Types.UNIT => Log.success("Unit")
    | Types.BOT => Log.success("⊥")
    | Types.ARRAY(t, _) => 
        Log.flatMap(typeToString(pos)(t), fn x => Log.success("Array of " ^ x))
    |  Types.RECORD(lst, _) => 
        let val fields = Log.all (map (fn (s, t) => typeToString(pos)(t)) lst)
        in Log.map(fields, fn strs => "RECORD(" ^ (String.concatWith ", " strs) ^ ")")
        end
    | Types.NAME(_, _) =>
        let 
          val tts = typeToString(pos)
          val Types.NAME(sym, _) = ty
          val actual = actualType(ty, pos)
          val actualStr = Log.flatMap(actual, tts)
        in
          Log.map(actualStr, fn str => (S.name sym) ^ " = " ^ str)
        end

  fun checkInt(ty, pos): unit Log.log = 
    Log.flatMap(actualType(ty, pos), fn at =>
    Log.flatMap(typeToString(pos)(ty), fn tStr =>
      if teq(at, Types.INT)
      then Log.success()
      else Log.failure((), pos, "Integer required, but was given " ^ tStr)))

  fun checkMatch(ty1, ty2, pos): unit Log.log = 
    Log.flatMap(actualType(ty1, pos), fn at1 => 
    Log.flatMap(actualType(ty2, pos), fn at2 =>
    Log.flatMap(typeToString(pos)(ty1), fn tStr1 =>
    Log.flatMap(typeToString(pos)(ty2), fn tStr2 =>
        if teq(at1, at2)
        then Log.success()
        else Log.failure((), pos,  ("Types must match;\n" ^
                                    " | LHS: " ^ tStr1 ^ "\n" ^
                                    " | RHS: " ^ tStr2))))))

  fun checkMatchIntStr(ty1, ty2, pos): unit Log.log = 
    Log.flatMap(actualType(ty1, pos), fn at1 => 
    Log.flatMap(actualType(ty2, pos), fn at2 =>
    Log.flatMap(typeToString(pos)(ty1), fn tStr1 =>
    Log.flatMap(typeToString(pos)(ty2), fn tStr2 =>
        if (teq(at1, Types.INT) andalso teq(at2, Types.INT)) orelse 
           (teq(at1, Types.STRING) andalso teq(at2, Types.STRING))
        then Log.success()
        else Log.failure((), pos, ("Types must match and be either int or string.\n" ^ 
                                   " | LHS: " ^ tStr1 ^ "\n" ^
                                   " | RHS: " ^ tStr2))))))

  fun matchOrdered(nil, nil, pos, n, len) = Log.success()
    | matchOrdered(_, nil, pos, n, len) = 
        Log.failure((), pos, 
          ("Received less arguments than expected .\n" ^
           " | Expected: " ^ (Int.toString len) ^ "\n" ^
           " | Actual:   " ^ (Int.toString n)))
    | matchOrdered(nil, rst, pos, n, len) = 
        Log.failure((), pos, 
          ("Received more arguments than expected .\n" ^
           " | Expected: " ^ (Int.toString len) ^ "\n" ^
           " | Actual:   " ^ (Int.toString (n + length rst))))
    | matchOrdered(t1::rst1, t2::rst2, pos, n, len) = 
        Log.flatMap(actualType(t1, pos), fn at1 => 
        Log.flatMap(actualType(t2, pos), fn at2 =>
        Log.flatMap(typeToString(pos)(t1), fn tStr1 =>
        Log.flatMap(typeToString(pos)(t2), fn tStr2 =>
        Log.flatMap(
            if teq(at1, at2)
            then Log.success()
            else Log.failure((), pos, ("Type mismatch at argument index " ^ (Int.toString n) ^ ".\n" ^
                                       " | Expected: " ^ tStr1 ^ "\n" ^
                                       " | Actual:   " ^ tStr2)), 
            fn () => matchOrdered(rst1, rst2, pos, n+1, len))))))

  fun fieldName({name=name, escape=_, typ=_, pos=_}) = name

  fun transTy(tenv: tenv, typ: A.ty): Types.ty Log.log = 
    let
      fun nameTy(sym, pos) = 
        case S.look(tenv, sym) of
          SOME(t) => Log.success(t)
        | NONE => Log.failure(Types.BOT, pos, "Could not resolve type " ^ (S.name sym))
    in
      case typ of
           A.NameTy(sym, pos) => nameTy(sym, pos)
         | A.RecordTy(fields) => Log.success(Types.UNIT)
         | A.ArrayTy(sym, pos) => Log.success(Types.UNIT)
    end

  and transVar(venv: venv, tenv: tenv, variable: A.var): expty Log.log = 
    let 
      fun simpleVar(sym, pos) = 
        case S.look(venv, sym) of
          SOME(Env.VarEntry{ty}) => 
            Log.map(actualType(ty, pos), fn at => { exp = (), ty = at })
        | _ => 
            Log.failure({ exp = (), ty = Types.BOT }, pos, "Could not resolve variable " ^ (S.name sym))

      fun fieldVar(var, sym, pos) = 
        let 
          fun findSym(nil, s, pos) =  
                Log.failure({ exp = (), ty = Types.BOT }, pos, "Field ." ^ (S.name s) ^ " does not exist")
            | findSym((sym, t)::rst, s, pos) = 
                Log.flatMap(actualType(t, pos), fn at =>
                  if (S.id sym) = (S.id s)
                  then Log.success({ exp = (), ty = at })
                  else findSym(rst, s, pos))

          fun resolve({exp=_, ty=t}) =
            case t of
              Types.RECORD(fields, _) => findSym(fields, sym, pos)
            | _ => Log.failure({ exp = (), ty = Types.BOT }, pos, "The variable is not a RECORD")
        in
          Log.flatMap(transVar(venv, tenv, var), resolve)
        end
    in
      case variable of
           A.SimpleVar(sym, pos) => simpleVar(sym, pos)
         | A.FieldVar(var, sym, pos) => fieldVar(var, sym, pos)
         | A.SubscriptVar(var, sym, pos) => Log.success(PLACEHOLDER)
    end

  and transExp(venv: venv, tenv: tenv, expression: A.exp): expty Log.log = 
    let

      fun trExp(expression: A.exp): expty Log.log = case expression of
         A.VarExp(var) => transVar(venv, tenv, var)
       | A.NilExp => Log.success({ exp=(), ty=Types.NIL })
       | A.IntExp(value) => Log.success({ exp=(), ty=Types.INT })
       | A.StringExp(str, pos) => Log.success({ exp=(), ty=Types.STRING })
       | A.CallExp{func, args, pos} => callExp(func, args, pos)
       | A.OpExp{left, oper, right, pos} => opExp(left, oper, right, pos)
       | A.RecordExp{fields, typ, pos} => Log.success(PLACEHOLDER)
       | A.SeqExp(exps) => seqExp(exps)
       | A.AssignExp{var, exp, pos} => Log.success(PLACEHOLDER)
       | A.IfExp{test, then', else', pos} => Log.success(PLACEHOLDER)
       | A.WhileExp{test, body, pos} => Log.success(PLACEHOLDER)
       | A.ForExp{var, escape, lo, hi, body, pos} => Log.success(PLACEHOLDER)
       | A.BreakExp(pos) => Log.success(PLACEHOLDER)
       | A.LetExp{decs, body, pos} => letExp(decs, body, pos)
       | A.ArrayExp{typ, size, init, pos} => Log.success(PLACEHOLDER)

      and seqExp(nil) = Log.success({ exp = (), ty = Types.UNIT })
        | seqExp((exp, pos) :: nil) = trExp(exp) 
        | seqExp((exp, pos) :: exps) = Log.flatMap(trExp(exp), fn (_) => seqExp(exps))

      and opExp(left, A.PlusOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkInt(leftTy, pos), fn () =>
            Log.flatMap(checkInt(rightTy, pos), fn () =>
              Log.success({exp=(), ty=Types.INT})))))
        | opExp(left, A.MinusOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkInt(leftTy, pos), fn () =>
            Log.flatMap(checkInt(rightTy, pos), fn () =>
              Log.success({exp=(), ty=Types.INT})))))
        | opExp(left, A.TimesOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkInt(leftTy, pos), fn () =>
            Log.flatMap(checkInt(rightTy, pos), fn () =>
              Log.success({exp=(), ty=Types.INT})))))
        | opExp(left, A.DivideOp, right, pos) =
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkInt(leftTy, pos), fn () =>
            Log.flatMap(checkInt(rightTy, pos), fn () =>
              Log.success({exp=(), ty=Types.INT})))))
        | opExp(left, A.EqOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkMatch(leftTy, rightTy, pos), fn () => 
              Log.success({exp=(), ty=Types.INT}))))
        | opExp(left, A.NeqOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkMatch(leftTy, rightTy, pos), fn () => 
              Log.success({exp=(), ty=Types.INT}))))
        | opExp(left, A.LtOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkMatchIntStr(leftTy, rightTy, pos), fn () => 
              Log.success({exp=(), ty=Types.INT}))))
        | opExp(left, A.LeOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkMatchIntStr(leftTy, rightTy, pos), fn () => 
              Log.success({exp=(), ty=Types.INT}))))
        | opExp(left, A.GtOp, right, pos) = 
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkMatchIntStr(leftTy, rightTy, pos), fn () => 
              Log.success({exp=(), ty=Types.INT}))))
        | opExp(left, A.GeOp, right, pos) =
            Log.flatMap(trExp left, fn ({exp=_, ty=leftTy}) =>
            Log.flatMap(trExp right, fn ({exp=_, ty=rightTy}) =>
            Log.flatMap(checkMatchIntStr(leftTy, rightTy, pos), fn () => 
              Log.success({exp=(), ty=Types.INT}))))

      and callExp(func, args, pos) = 
        case S.look(venv, func) of 
             SOME(Env.FunEntry{formals, result}) => 
               let
                 val translated = Log.all (map trExp args)
                 val types = Log.map(translated, fn lst => map (fn ({exp, ty}) => ty) lst) 
                 val res = Log.flatMap(types, fn lst => 
                  matchOrdered(List.rev formals, List.rev lst, pos, 0, length formals))
               in
                 Log.map(res, fn (_) => { exp = (), ty = result })
               end
           | _ => 
               Log.failure({ exp = (), ty = Types.BOT }, pos, "Undefined function " ^ (S.name func))

      and letExp(decs, body, pos) = 
        Log.flatMap(transDecs(venv, tenv, decs), fn ({venv, tenv}) => transExp(venv, tenv, body))

    in
      trExp expression
    end

  and transDecs(venv: venv, tenv: tenv, decs: A.dec list): { venv: venv, tenv: tenv} Log.log = 
    let 
      fun reduce(dec, envs) = 
        Log.flatMap(envs, fn ({venv, tenv}) => transDec(venv, tenv, dec))
    in
      foldl reduce (Log.success({venv=venv, tenv=tenv})) decs
    end

  and transDec(venv: venv, tenv: tenv, declaration: A.dec): { venv: venv, tenv: tenv } Log.log = 
    let
      fun varDec(name, escape, typ, init, pos) = 
        Log.flatMap(transExp(venv, tenv, init), fn ({exp=_, ty=initType}) =>
        Log.flatMap(
          case typ of 
            SOME((s, _)) => 
              (case S.look(tenv, s) of 
                 SOME(t) => Log.success(t)
               | NONE => Log.failure(Types.BOT, pos, "Undeclared type " ^ (S.name s)))
          | NONE => Log.success(initType), 

          fn decType =>
        Log.flatMap(actualType(initType, pos), fn actualInitType => 
        Log.flatMap(actualType(decType, pos), fn actualDecType =>
        Log.flatMap(typeToString(pos)(initType), fn initTypeStr =>
        Log.flatMap(typeToString(pos)(decType), fn decTypeStr =>
          if teq(actualInitType, actualDecType)
          then Log.success({venv=S.enter(venv, name, Env.VarEntry{ty=decType}),
                            tenv=tenv})
          else Log.failure(
                {venv=S.enter(venv, name, Env.VarEntry{ty=decType}),
                 tenv=tenv}, pos,
                 ("The initializer's type does not " ^ 
                 "match the declared type.\n" ^
                 "| Initializer: " ^ initTypeStr ^ "\n" ^
                 "| Declared:    " ^ decTypeStr))))))))

      fun typeDecs(typedecs) = 
        let 
          val headerEnv = foldl
            (fn ({name, ty, pos}, acc) => S.enter(acc, name, Types.NAME(name, ref NONE)))
            tenv 
            typedecs

          val logs = Log.all (
            map 
            (fn ({name, ty, pos}) => 
              Log.map(transTy(headerEnv, ty), fn ty => 
                let val SOME(Types.NAME(_, r)) = S.look(headerEnv, name)
                in r := SOME(ty)
                end))
            typedecs)
        in
          Log.map(logs, fn (_) => { venv = venv, tenv = headerEnv })
        end 

      fun functionDecs(fundecs) =
        let
          fun fieldToTy({name=_, escape=_, typ=sym, pos=pos}) = 
            case S.look(tenv, sym) of
              SOME(ty) => actualType(ty, pos)
            | NONE => Log.failure(Types.BOT, pos, "Undeclared type " ^ (S.name sym));

          fun resultToTy(NONE) = Log.success(Types.UNIT)
            | resultToTy(SOME(sym, pos)) =
                case S.look(tenv, sym) of
                  SOME(ty) => actualType(ty, pos)
                | NONE => Log.failure(Types.BOT, pos, "Undeclared type " ^ (S.name sym));

          val headerEnv = foldr
            (fn ({name, params, result, body, pos}, acc) =>
              Log.flatMap(acc, fn env => 
              Log.flatMap(Log.all (map fieldToTy params), fn paramTys => 
              Log.map(resultToTy result, fn resultTy => 
                S.enter(env, name, Env.FunEntry{formals=paramTys, result=resultTy})))))
            (Log.success venv)
            fundecs

          fun withParams(params, venv) = foldl 
            (fn (field, acc) => 
              Log.flatMap(acc, fn acc => 
              Log.map(fieldToTy field, fn fieldTy => 
                S.enter(acc, fieldName field, Env.VarEntry{ty=fieldTy}))))
            (Log.success venv)
            params
          
          fun bodyCheck({name, params, result, body, pos}) = 
            Log.flatMap(headerEnv, fn env =>
            Log.flatMap(withParams(params, env), fn funEnv =>
            Log.flatMap(transExp(funEnv, tenv, body), fn ({exp=_, ty=resTy}) =>
            Log.flatMap(resultToTy result, fn decResTy => 
            Log.flatMap(actualType(resTy, pos), fn resAT =>
            Log.flatMap(actualType(decResTy, pos), fn decResAT =>
            Log.flatMap(typeToString(pos)(resTy), fn resTyStr =>
            Log.flatMap(typeToString(pos)(decResTy), fn decResTyStr =>
              if teq(resAT, decResAT)
              then Log.success()
              else Log.failure((), pos, ("The body's result type and declared result type " ^ 
                                         "does not match. \n" ^
                                         " | Declared: " ^ decResTyStr ^ "\n" ^
                                         " | Actual:   " ^ resTyStr))))))))))

          val logs = Log.all (map bodyCheck fundecs)
        in
          Log.flatMap(logs, fn (_) => 
          Log.map(headerEnv, fn headerEnv => 
            { venv = headerEnv, tenv = tenv }))
        end
    in
      case declaration of
           A.FunctionDec(fundecs) => functionDecs(fundecs)
         | A.VarDec{name, escape, typ, init, pos} => varDec(name, escape, typ, init, pos)
         | A.TypeDec(typedecs) => typeDecs(typedecs)
    end

  fun transProg (absyn: A.exp): unit = 
    (Log.report (transExp(Env.base_venv, Env.base_tenv, absyn)); ())
end
