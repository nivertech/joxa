%% -*- mode: Erlang; fill-column: 80; comment-column: 76; -*-
-module(jxa_expression).

-export([do_function_body/4, comp/3]).
-include_lib("joxa/include/joxa.hrl").

%%=============================================================================
%% Public API
%%=============================================================================
do_function_body(Path0, Ctx0, Args, Expression) ->
    {Ctx1, ArgList} = gen_args(jxa_path:add(Path0), Ctx0, Args),
    Ctx2 = jxa_ctx:add_variables_to_scope(Args, jxa_ctx:push_scope(Ctx1)),

    {Ctx3, Body} = comp(jxa_path:add(jxa_path:incr(Path0)),
                        Ctx2, Expression),
    {jxa_ctx:pop_scope(Ctx3), ArgList, Body}.

comp(Path0, Ctx0, Arg) when is_atom(Arg) ->
    {_, Idx = {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                         jxa_ctx:annots(Ctx0)),
    case jxa_ctx:resolve_reference(Arg, -1, Ctx0) of
        {variable, Var} ->
            {Ctx0, cerl:set_ann(Var, [Line])};
        _ ->
            ?JXA_THROW({undefined_reference, Arg, Idx})
    end;
comp(Path0, Ctx0, {'__fun__', F, A}) when is_integer(A) ->
    {_, Idx = {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                         jxa_ctx:annots(Ctx0)),
    case jxa_ctx:resolve_reference(F, A, Ctx0) of
        {variable, Var} ->
            case cerl:is_c_fname(Var) andalso
                cerl:fname_arity(Var) == A of
                true ->
                    {Ctx0, cerl:set_ann(Var, [Line])};
                false ->
                    ?JXA_THROW({invalid_reference, {F, A}, Idx})
            end;
        {apply, Name, A} ->
            {Ctx0, cerl:ann_c_fname([Line], Name, A)};
        _ ->
            ?JXA_THROW({undefined_reference, {F, A}, Idx})
    end;
comp(Path0, Ctx0, Ref = {'__fun__', _, _, A}) when is_integer(A) ->
    {_, Idx = {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                         jxa_ctx:annots(Ctx0)),
    case jxa_ctx:resolve_reference(Ref, A, Ctx0) of
        {variable, _Var} ->
            ?JXA_THROW({invalid_refrence, Ref, Idx});
        {remote, Module, Function} ->
           {Ctx0, cerl:ann_c_call([Line],
                                  cerl:ann_c_atom([Line],
                                                  erlang),
                                  cerl:ann_c_atom([Line],
                                                  make_fun),
                                  [cerl:ann_c_atom([Line], Module),
                                   cerl:ann_c_atom([Line], Function),
                                   cerl:ann_c_int([Line], A)])};
        _ ->
            ?JXA_THROW({undefined_reference, Ref, Idx})
    end;
comp(Path0, Ctx0, Arg) when is_atom(Arg) ->
    {_, {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                   jxa_ctx:annots(Ctx0)),
    {Ctx0, cerl:ann_c_atom([Line], Arg)};
comp(Path0, Ctx0, Arg) when is_integer(Arg) ->
    {_, {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                   jxa_ctx:annots(Ctx0)),
    {Ctx0, cerl:ann_c_int([Line], Arg)};
comp(Path0, Ctx0, Arg) when is_float(Arg) ->
    {_, {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                   jxa_ctx:annots(Ctx0)),
    {Ctx0, cerl:ann_c_float([Line], Arg)};
comp(Path0, Ctx0, Arg) when is_tuple(Arg) ->
    mk_tuple(Path0, Ctx0, tuple_to_list(Arg));
comp(Path0, Ctx0, Form = ['let' | _]) ->
    jxa_let:comp(Path0, Ctx0, Form);
comp(Path0, Ctx0, [do | Args]) ->
    mk_do(jxa_path:incr(Path0), Ctx0, Args);
comp(Path0, Ctx0, [values | Args0]) ->
    {Ctx2, Args1} = eval_args(jxa_path:incr(Path0), Ctx0, Args0),
    {_, {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                   jxa_ctx:annots(Ctx0)),
    {Ctx2, cerl:ann_c_values([Line], lists:reverse(Args1))};
comp(Path0, Ctx0, [Arg1, '.', Arg2]) ->
    {Ctx1, Cerl1} = comp(Path0,
                         Ctx0, Arg1),
    {Ctx2, Cerl2} = comp(jxa_path:incr(2, Path0),
                         Ctx1, Arg2),
    {_, {Line, _}} = jxa_annot:get(jxa_path:add_path(Path0),
                                   jxa_ctx:annots(Ctx2)),
    {Ctx2, cerl:ann_c_cons(Line, Cerl1, Cerl2)};
comp(Path0, Ctx0, [apply, {'__fun__', Module, Function, _A} | Args]) ->
    {_, {Line, _}} = jxa_annot:get(jxa_path:add_path(Path0),
                                   jxa_ctx:annots(Ctx0)),
    {Ctx1, ArgList} =  eval_args(jxa_path:incr(2, Path0),
                                 Ctx0, Args),
    {Ctx1, cerl:ann_c_call([Line],
                           cerl:ann_c_atom([Line],
                                           Module),
                           cerl:ann_c_atom([Line],
                                           Function),
                           ArgList)};
comp(Path0, Ctx0, [apply, Target | Args]) ->
    {_, Idx={Line, _}} = jxa_annot:get(jxa_path:add_path(Path0),
                                   jxa_ctx:annots(Ctx0)),
    {Ctx1, CerlTarget} = comp(jxa_path:add(jxa_path:incr(Path0)),
                              Ctx0, Target),
    {Ctx2, CerlArgList} =  eval_args(jxa_path:incr(2, Path0),
                                     Ctx1, Args),
    case cerl:is_c_fname(CerlTarget) of
        true ->
            case cerl:fname_arity(CerlTarget) == erlang:length(CerlArgList) of
                true ->
                    {Ctx2, cerl:ann_c_apply([Line],
                                            CerlTarget,
                                            CerlArgList)};
                false ->
                    ?JXA_THROW({invalid_arity, Idx})
            end;
        false ->
            {Ctx2, cerl:ann_c_apply([Line],
                                    CerlTarget,
                                    CerlArgList)}
    end;
comp(Path0, Ctx0, [cons, Arg1, Arg2]) ->
            {Ctx1, Cerl1} = comp(jxa_path:incr(Path0),
                                 Ctx0, Arg1),
    {Ctx2, Cerl2} = comp(jxa_path:incr(2, Path0),
                         Ctx1, Arg2),
    {ident, {Line, _}} = jxa_annot:get(jxa_path:add_path(Path0),
                                       jxa_ctx:annots(Ctx2)),
    {Ctx2, cerl:ann_c_cons(Line, Cerl1, Cerl2)};
comp(Path0, Ctx0, [quote, Args]) ->
    Literal = jxa_literal:comp(jxa_path:incr(Path0), Ctx0, Args),
    {Ctx0, Literal};
comp(Path0, Ctx0, [list | Args]) ->
    Path1 = jxa_path:incr(Path0),
    convert_list(Path1, Ctx0, Args);
comp(Path0, Ctx0, [fn, Args, Expression]) ->
    {Ctx1, ArgList, Body} =
        do_function_body(jxa_path:incr(Path0), Ctx0,
                         Args, Expression),
    {_, {Line, _}} = jxa_annot:get(jxa_path:add_path(Path0),
                                   jxa_ctx:annots(Ctx1)),
    CerlFun = cerl:ann_c_fun([Line], ArgList, Body),
    {Ctx1, CerlFun};
comp(Path0, Ctx0, [tuple | Args]) ->
    mk_tuple(Path0, Ctx0, Args);
comp(Path0, Ctx0, Form = [Val | Args]) ->
    case jxa_annot:get(jxa_path:path(Path0), jxa_ctx:annots(Ctx0)) of
        {string, {Line, _}} ->
            {Ctx0, cerl:ann_c_string([Line], Form)};
        {Type, Idx={BaseLine, _}} when Type == list; Type == vector ->
            PossibleArity = erlang:length(Args),
            Path1 = jxa_path:add(Path0),
            {_, {CallLine, _}} =
                jxa_annot:get(jxa_path:path(Path1),
                              jxa_ctx:annots(Ctx0)),
            {Ctx1, ArgList} = eval_args(jxa_path:incr(Path0),
                                        Ctx0, Args),
            case jxa_ctx:resolve_reference(Val, PossibleArity, Ctx1) of
                {variable, Var} ->
                    {Ctx1, cerl:ann_c_apply([BaseLine],
                                            cerl:set_ann(Var, [BaseLine]),
                                            ArgList)};
                {apply, Name, Arity} ->
                    {Ctx1, cerl:ann_c_apply([BaseLine],
                                            cerl:ann_c_fname([CallLine],
                                                             Name,
                                                             Arity),
                                            ArgList)};
                {remote, Module, Function} ->
                    {Ctx1, cerl:ann_c_call([BaseLine],
                                           cerl:ann_c_atom([CallLine],
                                                           Module),
                                           cerl:ann_c_atom([CallLine],
                                                           Function),
                                           ArgList)};
                {error, Error1 = {mismatched_arity, _, _, _}} ->
                    ?JXA_THROW({Error1, Idx});
                {error, Error2 = {mismatched_arity, _, _, _, _}} ->
                    ?JXA_THROW({Error2, Idx});
                not_a_reference ->
                    %% The last thing it might be is a function call. So we
                    %% are going to try to compile it. It might work
                    {Ctx1, Cerl} = comp(Path1, Ctx1, Val),
                    {Ctx1, cerl:ann_c_apply([BaseLine], Cerl, ArgList)}
            end
    end;
comp(Path0, Ctx0, _Form) ->
    {_, Idx} = jxa_annot:get(jxa_path:path(Path0), jxa_ctx:annots(Ctx0)),
    ?JXA_THROW({invalid_form, Idx}).

mk_tuple(Path0, Ctx0, Args) ->
    {_, Ctx3, Body} =
        lists:foldl(fun(Arg, {Path2, Ctx1, Acc}) ->
                            {Ctx2, Element} =
                                comp(jxa_path:add(Path2), Ctx1, Arg),
                            Path3 = jxa_path:incr(Path2),
                            {Path3, Ctx2, [Element | Acc]}
                    end, {Path0, Ctx0, []}, Args),
    {_, {Line, _}} = jxa_annot:get(jxa_path:path(Path0),
                                   jxa_ctx:annots(Ctx3)),
    {Ctx3, cerl:ann_c_tuple([Line], lists:reverse(Body))}.

convert_list(_Path0, Ctx0, []) ->
    {Ctx0, cerl:c_nil()};
convert_list(Path0, Ctx0, [H | T]) ->
    {Ctx1, CerlH} = comp(jxa_path:add(Path0),
                         Ctx0, H),
    {Ctx2, CerlT} = convert_list(jxa_path:incr(Path0),
                                 Ctx1, T),
    {_, {Line, _}} = jxa_annot:get(
                       jxa_path:add_path(Path0),
                       jxa_ctx:annots(Ctx2)),
    {Ctx2, cerl:ann_c_cons([Line], CerlH, CerlT)}.

eval_args(Path0, Ctx0, Args0) ->
    {_, Ctx3, Args1} =
        lists:foldl(fun(Arg, {Path1, Ctx1, Acc}) ->
                            {Ctx2, Cerl} =
                                comp(jxa_path:add(Path1), Ctx1, Arg),
                            Path2 = jxa_path:incr(Path1),
                            {Path2, Ctx2, [Cerl | Acc]}
                    end, {Path0, Ctx0, []}, Args0),
    {Ctx3, lists:reverse(Args1)}.

gen_args(Path0, Ctx0, Args0) ->
    {_, Ctx2, Args1} =
        lists:foldl(fun(Arg, {Path1, Ctx1, Acc})
                          when is_atom(Arg) ->
                            {_, {Line, _}} =
                                jxa_annot:get(jxa_path:add_path(Path1),
                                              jxa_ctx:annots(Ctx1)),
                            Path2 = jxa_path:incr(Path1),
                            {Path2, Ctx1, [cerl:ann_c_var([Line], Arg) | Acc]};
                       (_Arg, {Path1, Ctx1, _}) ->
                            Path2 = jxa_path:incr(Path1),
                            {_, {Line, Char}} =
                                jxa_annot:get(jxa_path:add_path(Path2),
                                              jxa_ctx:annots(Ctx1)),
                            ?JXA_THROW({invalid_arg, Line, Char})
                    end, {Path0, Ctx0, []}, Args0),
    {Ctx2, lists:reverse(Args1)}.

mk_do(Path0, Ctx0, [Arg1, Arg2]) ->
    {_, {Line, _}} =
        jxa_annot:get(jxa_path:add_path(Path0), jxa_ctx:annots(Ctx0)),
    {Ctx1, Cerl0} = comp(jxa_path:add(Path0), Ctx0, Arg1),
    {Ctx2, Cerl1} = comp(jxa_path:add(jxa_path:incr(Path0)), Ctx1, Arg2),
    {Ctx2, cerl:ann_c_seq([Line], Cerl0, Cerl1)};
mk_do(Path0, Ctx0, [Arg1]) ->
    {_, {Line, _}} =
        jxa_annot:get(jxa_path:add_path(Path0), jxa_ctx:annots(Ctx0)),
    {Ctx1, Cerl0} = comp(jxa_path:add(Path0), Ctx0, Arg1),
    {Ctx1, cerl:ann_c_seq([Line], cerl:c_nil(), Cerl0)};
mk_do(Path0, Ctx0, [Arg1 | Rest]) ->
    {_, {Line, _}} =
        jxa_annot:get(jxa_path:add_path(Path0), jxa_ctx:annots(Ctx0)),
    {Ctx1, Cerl0} = comp(jxa_path:add(Path0), Ctx0, Arg1),
    {Ctx2, Cerl1} = mk_do(jxa_path:incr(Path0), Ctx1, Rest),
    {Ctx2, cerl:ann_c_seq([Line], Cerl0, Cerl1)}.

