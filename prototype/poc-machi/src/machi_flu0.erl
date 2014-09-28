-module(machi_flu0).

-behaviour(gen_server).

-include("machi.hrl").

-export([start_link/1, stop/1,
         write/3, read/2, trim/2,
         proj_write/3, proj_read/2, proj_get_latest_num/1, proj_read_latest/1]).
-export([make_proj/1, make_proj/2]).

-ifdef(TEST).
-compile(export_all).
-endif.

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-ifdef(PULSE).
-compile({parse_transform, pulse_instrument}).
-endif.
-endif.

-define(SERVER, ?MODULE).
-define(LONG_TIME, infinity).
%% -define(LONG_TIME, 30*1000).
%% -define(LONG_TIME, 5*1000).

-type register() :: 'unwritten' | binary() | 'trimmed'.

-record(state, {
          name :: list(),
          wedged = false :: boolean(),
          register = 'unwritten' :: register(),
          proj_epoch :: non_neg_integer(),
          proj_store :: dict()
         }).

start_link(Name) when is_list(Name) ->
    gen_server:start_link(?MODULE, [Name], []).

stop(Pid) ->
    g_call(Pid, stop, infinity).

read(Pid, Epoch) ->
    g_call(Pid, {reg_op, Epoch, read}, ?LONG_TIME).

write(Pid, Epoch, Bin) ->
    g_call(Pid, {reg_op, Epoch, {write, Bin}}, ?LONG_TIME).

trim(Pid, Epoch) ->
    g_call(Pid, {reg_op, Epoch, trim}, ?LONG_TIME).

proj_write(Pid, Epoch, Proj) ->
    g_call(Pid, {proj_write, Epoch, Proj}, ?LONG_TIME).

proj_read(Pid, Epoch) ->
    g_call(Pid, {proj_read, Epoch}, ?LONG_TIME).

proj_get_latest_num(Pid) ->
    g_call(Pid, {proj_get_latest_num}, ?LONG_TIME).

proj_read_latest(Pid) ->
    g_call(Pid, {proj_read_latest}, ?LONG_TIME).

g_call(Pid, Arg, Timeout) ->
    LC1 = lclock_get(),
    {Res, LC2} = gen_server:call(Pid, {Arg, LC1}, Timeout),
    lclock_update(LC2),
    Res.

%%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%%

make_proj(FLUs) ->
    make_proj(1, FLUs).

make_proj(Epoch, FLUs) ->
    #proj{epoch=Epoch, all=FLUs, active=FLUs}.

%%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%%

init([Name]) ->
    lclock_init(),
    {ok, #state{name=Name,
                proj_epoch=-42,
                proj_store=orddict:new()}}.

handle_call({{reg_op, _Epoch, _}, LC1}, _From, #state{wedged=true} = S) ->
    LC2 = lclock_update(LC1),
    {reply, {error_wedged, LC2}, S};
handle_call({{reg_op, Epoch, _}, LC1}, _From, #state{proj_epoch=MyEpoch} = S)
  when Epoch < MyEpoch ->
    LC2 = lclock_update(LC1),
    {reply, {{error_stale_projection, MyEpoch}, LC2}, S};
handle_call({{reg_op, Epoch, _}, LC1}, _From, #state{proj_epoch=MyEpoch} = S)
  when Epoch > MyEpoch ->
    LC2 = lclock_update(LC1),
    {reply, {error_wedged, LC2}, S#state{wedged=true}};

handle_call({{reg_op, _Epoch, {write, Bin}}, LC1}, _From,
             #state{register=unwritten} = S) ->
    LC2 = lclock_update(LC1),
    {reply, {ok, LC2}, S#state{register=Bin}};
handle_call({{reg_op, _Epoch, {write, _Bin}}, LC1}, _From,
            #state{register=B} = S) when is_binary(B) ->
    LC2 = lclock_update(LC1),
    {reply, {error_written, LC2}, S};
handle_call({{reg_op, _Epoch, {write, _Bin}}, LC1}, _From,
            #state{register=trimmed} = S) ->
    LC2 = lclock_update(LC1),
    {reply, {error_trimmed, LC2}, S};

handle_call({{reg_op, Epoch, read}, LC1}, _From, #state{proj_epoch=MyEpoch} = S)
  when Epoch /= MyEpoch ->
    LC2 = lclock_update(LC1),
    {reply, {{error_stale_projection, MyEpoch}, LC2}, S};
handle_call({{reg_op, _Epoch, read}, LC1}, _From, #state{register=Reg} = S) ->
    LC2 = lclock_update(LC1),
    {reply, {{ok, Reg}, LC2}, S};

handle_call({{reg_op, _Epoch, trim}, LC1}, _From, #state{register=unwritten} = S) ->
    LC2 = lclock_update(LC1),
    {reply, {ok, LC2}, S#state{register=trimmed}};
handle_call({{reg_op, _Epoch, trim}, LC1}, _From, #state{register=B} = S) when is_binary(B) ->
    LC2 = lclock_update(LC1),
    {reply, {ok, LC2}, S#state{register=trimmed}};
handle_call({{reg_op, _Epoch, trim}, LC1}, _From, #state{register=trimmed} = S) ->
    LC2 = lclock_update(LC1),
    {reply, {error_trimmed, LC2}, S};

handle_call({{proj_write, Epoch, Proj}, LC1}, _From, S) ->
    LC2 = lclock_update(LC1),
    {Reply, NewS} = do_proj_write(Epoch, Proj, S),
    {reply, {Reply, LC2}, NewS};
handle_call({{proj_read, Epoch}, LC1}, _From, S) ->
    LC2 = lclock_update(LC1),
    {Reply, NewS} = do_proj_read(Epoch, S),
    {reply, {Reply, LC2}, NewS};
handle_call({{proj_get_latest_num}, LC1}, _From, S) ->
    LC2 = lclock_update(LC1),
    {Reply, NewS} = do_proj_get_latest_num(S),
    {reply, {Reply, LC2}, NewS};
handle_call({{proj_read_latest}, LC1}, _From, S) ->
    LC2 = lclock_update(LC1),
    case do_proj_get_latest_num(S) of
        {error_unwritten, _S} ->
            {reply, {error_unwritten, LC2}, S};
        {{ok, Epoch}, _S} ->
            Proj = orddict:fetch(Epoch, S#state.proj_store),
            {reply, {{ok, Proj}, LC2}, S}
    end;
handle_call({stop, LC1}, _From, MLP) ->
    LC2 = lclock_update(LC1),
    {stop, normal, {ok, LC2}, MLP};
handle_call(_Request, _From, MLP) ->
    Reply = whaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
    {reply, Reply, MLP}.

handle_cast(_Msg, MLP) ->
    {noreply, MLP}.

handle_info(_Info, MLP) ->
    {noreply, MLP}.

terminate(_Reason, _MLP) ->
    ok.

code_change(_OldVsn, MLP, _Extra) ->
    {ok, MLP}.

%%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%% %%%%

do_proj_write(Epoch, Proj, #state{proj_epoch=MyEpoch, proj_store=D,
                                    wedged=MyWedged} = S) ->
    case orddict:find(Epoch, D) of
        error ->
            D2 = orddict:store(Epoch, Proj, D),
            {NewEpoch, NewWedged} = if Epoch > MyEpoch ->
                                              {Epoch, false};
                                         true ->
                                              {MyEpoch, MyWedged}
                                      end,
            {ok, S#state{wedged=NewWedged,
                         proj_epoch=NewEpoch,
                         proj_store=D2}};
        {ok, _} ->
            {error_written, S}
    end.

do_proj_read(Epoch, #state{proj_store=D} = S) ->
    case orddict:find(Epoch, D) of
        error ->
            {error_unwritten, S};
        {ok, Proj} ->
            {{ok, Proj}, S}
    end.

do_proj_get_latest_num(#state{proj_store=D} = S) ->
    case lists:sort(orddict:to_list(D)) of
        [] ->
            {error_unwritten, S};
        L ->
            {Epoch, _Proj} = lists:last(L),
            {{ok, Epoch}, S}
    end.

-ifdef(TEST).

lclock_init() ->
    lamport_clock:init().

lclock_get() ->
    lamport_clock:get().

lclock_update(LC) ->
    lamport_clock:update(LC).

-else.  % PULSE

lclock_init() ->
    ok.

lclock_get() ->
    ok.

lclock_update(_LC) ->
    ok.

-endif. % TEST
