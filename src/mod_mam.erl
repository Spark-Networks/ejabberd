%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @doc
%%%      Message Archive Management (XEP-0313)
%%% @end
%%% Created :  4 Jul 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2013-2016   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(mod_mam).

-protocol({xep, 313, '0.4'}).
-protocol({xep, 334, '0.2'}).

-behaviour(gen_mod).

%% API
-export([start/2, stop/1]).

-export([user_send_packet/4, user_receive_packet/5,
	 process_iq_v0_2/3, process_iq_v0_3/3, disco_sm_features/5,
	 remove_user/2, remove_user/3, mod_opt_type/1, muc_process_iq/4,
	 muc_filter_message/5, message_is_archived/5, delete_old_messages/2,
	 get_commands_spec/0]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").
-include("logger.hrl").
-include("mod_muc_room.hrl").
-include("ejabberd_commands.hrl").

-define(DEF_PAGE_SIZE, 50).
-define(MAX_PAGE_SIZE, 250).

-define(BIN_GREATER_THAN(A, B),
	((A > B andalso byte_size(A) == byte_size(B))
	 orelse byte_size(A) > byte_size(B))).
-define(BIN_LESS_THAN(A, B),
	((A < B andalso byte_size(A) == byte_size(B))
	 orelse byte_size(A) < byte_size(B))).

-record(archive_msg,
	{us = {<<"">>, <<"">>}                :: {binary(), binary()} | '$2',
	 id = <<>>                            :: binary() | '_',
	 timestamp = p1_time_compat:timestamp() :: erlang:timestamp() | '_' | '$1',
	 peer = {<<"">>, <<"">>, <<"">>}      :: ljid() | '_' | '$3' | undefined,
	 bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_' | '$3',
	 packet = #xmlel{}                    :: xmlel() | '_',
	 nick = <<"">>                        :: binary(),
	 type = chat                          :: chat | groupchat}).

-record(archive_prefs,
	{us = {<<"">>, <<"">>} :: {binary(), binary()},
	 default = never       :: never | always | roster,
	 always = []           :: [ljid()],
	 never = []            :: [ljid()]}).

%%%===================================================================
%%% API
%%%===================================================================
start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
			     one_queue),
    DBType = gen_mod:db_type(Host, Opts),
    init_db(DBType, Host),
    init_cache(DBType, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_TMP, ?MODULE, process_iq_v0_2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_TMP, ?MODULE, process_iq_v0_2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_0, ?MODULE, process_iq_v0_3, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_0, ?MODULE, process_iq_v0_3, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_1, ?MODULE, process_iq_v0_3, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_1, ?MODULE, process_iq_v0_3, IQDisc),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
		       user_receive_packet, 500),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
		       user_send_packet, 500),
    ejabberd_hooks:add(muc_filter_message, Host, ?MODULE,
		       muc_filter_message, 50),
    ejabberd_hooks:add(muc_process_iq, Host, ?MODULE,
		       muc_process_iq, 50),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
		       disco_sm_features, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host, ?MODULE,
		       remove_user, 50),
    case gen_mod:get_opt(assume_mam_usage, Opts,
			 fun(if_enabled) -> if_enabled;
			    (on_request) -> on_request;
			    (never) -> never
			 end, never) of
	never ->
	    ok;
	_ ->
	    ejabberd_hooks:add(message_is_archived, Host, ?MODULE,
			       message_is_archived, 50)
    end,
    ejabberd_commands:register_commands(get_commands_spec()),
    ok.

init_db(mnesia, _Host) ->
    mnesia:create_table(archive_msg,
			[{disc_only_copies, [node()]},
			 {type, bag},
			 {attributes, record_info(fields, archive_msg)}]),
    mnesia:create_table(archive_prefs,
			[{disc_only_copies, [node()]},
			 {attributes, record_info(fields, archive_prefs)}]);
init_db(_, _) ->
    ok.

init_cache(_DBType, Opts) ->
    MaxSize = gen_mod:get_opt(cache_size, Opts,
			      fun(I) when is_integer(I), I>0 -> I end,
			      1000),
    LifeTime = gen_mod:get_opt(cache_life_time, Opts,
			       fun(I) when is_integer(I), I>0 -> I end,
			       timer:hours(1) div 1000),
    cache_tab:new(archive_prefs, [{max_size, MaxSize},
				  {life_time, LifeTime}]).

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
			  user_send_packet, 500),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
			  user_receive_packet, 500),
    ejabberd_hooks:delete(muc_filter_message, Host, ?MODULE,
			  muc_filter_message, 50),
    ejabberd_hooks:delete(muc_process_iq, Host, ?MODULE,
			  muc_process_iq, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_TMP),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_TMP),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_0),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_0),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_1),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_1),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
			  disco_sm_features, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    case gen_mod:get_module_opt(Host, ?MODULE, assume_mam_usage,
				fun(if_enabled) -> if_enabled;
				   (on_request) -> on_request;
				   (never) -> never
				end, never) of
	never ->
	    ok;
	_ ->
	    ejabberd_hooks:delete(message_is_archived, Host, ?MODULE,
				  message_is_archived, 50)
    end,
    ejabberd_commands:unregister_commands(get_commands_spec()),
    ok.

remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    remove_user(LUser, LServer,
		gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
		mnesia:delete({archive_msg, US}),
		mnesia:delete({archive_prefs, US})
	end,
    mnesia:transaction(F);
remove_user(LUser, LServer, odbc) ->
    SUser = ejabberd_odbc:escape(LUser),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from archive where username='">>, SUser, <<"';">>]),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from archive_prefs where username='">>, SUser, <<"';">>]).

user_receive_packet(Pkt, C2SState, JID, Peer, To) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    IsBareCopy = is_bare_copy(JID, To),
    case should_archive(Pkt, LServer) of
	true when not IsBareCopy ->
	    NewPkt = strip_my_archived_tag(Pkt, LServer),
	    case store_msg(C2SState, NewPkt, LUser, LServer, Peer, recv) of
		{ok, ID} ->
		    Archived = #xmlel{name = <<"archived">>,
				      attrs = [{<<"by">>, LServer},
					       {<<"xmlns">>, ?NS_MAM_TMP},
					       {<<"id">>, ID}]},
		    StanzaID = #xmlel{name = <<"stanza-id">>,
				      attrs = [{<<"by">>, LServer},
					       {<<"xmlns">>, ?NS_SID_0},
					       {<<"id">>, ID}]},
                    NewEls = [Archived, StanzaID|NewPkt#xmlel.children],
		    NewPkt#xmlel{children = NewEls};
		_ ->
		    NewPkt
	    end;
	_ ->
	    Pkt
    end.

user_send_packet(Pkt, C2SState, JID, Peer) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    case should_archive(Pkt, LServer) of
	true ->
	    NewPkt = strip_my_archived_tag(Pkt, LServer),
	    store_msg(C2SState, jlib:replace_from_to(JID, Peer, NewPkt),
		      LUser, LServer, Peer, send),
	    NewPkt;
	false ->
	    Pkt
    end.

muc_filter_message(Pkt, #state{config = Config} = MUCState,
		   RoomJID, From, FromNick) ->
    if Config#config.mam ->
	    LServer = RoomJID#jid.lserver,
	    NewPkt = strip_my_archived_tag(Pkt, LServer),
	    StorePkt = strip_x_jid_tags(NewPkt),
	    case store_muc(MUCState, StorePkt, RoomJID, From, FromNick) of
		{ok, ID} ->
		    Archived = #xmlel{name = <<"archived">>,
				      attrs = [{<<"by">>, LServer},
					       {<<"xmlns">>, ?NS_MAM_TMP},
					       {<<"id">>, ID}]},
		    StanzaID = #xmlel{name = <<"stanza-id">>,
				      attrs = [{<<"by">>, LServer},
                                               {<<"xmlns">>, ?NS_SID_0},
                                               {<<"id">>, ID}]},
                    NewEls = [Archived, StanzaID|NewPkt#xmlel.children],
                    NewPkt#xmlel{children = NewEls};
		_ ->
		    NewPkt
	    end;
	true ->
	    Pkt
    end.

% Query archive v0.2
process_iq_v0_2(#jid{lserver = LServer} = From,
	       #jid{lserver = LServer} = To,
	       #iq{type = get, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    Fs = parse_query_v0_2(SubEl),
    process_iq(LServer, From, To, IQ, SubEl, Fs, chat);
process_iq_v0_2(From, To, IQ) ->
    process_iq(From, To, IQ).

% Query archive v0.3
process_iq_v0_3(#jid{lserver = LServer} = From,
		#jid{lserver = LServer} = To,
		#iq{type = set, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    process_iq(LServer, From, To, IQ, SubEl, get_xdata_fields(SubEl), chat);
process_iq_v0_3(#jid{lserver = LServer},
		#jid{lserver = LServer},
		#iq{type = get, sub_el = #xmlel{name = <<"query">>}} = IQ) ->
    process_iq(LServer, IQ);
process_iq_v0_3(From, To, IQ) ->
    process_iq(From, To, IQ).

muc_process_iq(#iq{type = set,
		   sub_el = #xmlel{name = <<"query">>,
				   attrs = Attrs} = SubEl} = IQ,
	       MUCState, From, To) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	NS when NS == ?NS_MAM_0; NS == ?NS_MAM_1 ->
	    muc_process_iq(IQ, MUCState, From, To, get_xdata_fields(SubEl));
	_ ->
	    IQ
    end;
muc_process_iq(#iq{type = get,
		   sub_el = #xmlel{name = <<"query">>,
				   attrs = Attrs} = SubEl} = IQ,
	       MUCState, From, To) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	?NS_MAM_TMP ->
	    muc_process_iq(IQ, MUCState, From, To, parse_query_v0_2(SubEl));
	NS when NS == ?NS_MAM_0; NS == ?NS_MAM_1 ->
	    LServer = MUCState#state.server_host,
	    process_iq(LServer, IQ);
	_ ->
	    IQ
    end;
muc_process_iq(IQ, _MUCState, _From, _To) ->
    IQ.

get_xdata_fields(SubEl) ->
    case {fxml:get_subtag_with_xmlns(SubEl, <<"x">>, ?NS_XDATA),
	  fxml:get_subtag_with_xmlns(SubEl, <<"set">>, ?NS_RSM)} of
	{#xmlel{} = XData, false} ->
	    jlib:parse_xdata_submit(XData);
	{#xmlel{} = XData, #xmlel{}} ->
	    [{<<"set">>, SubEl} | jlib:parse_xdata_submit(XData)];
	{false, #xmlel{}} ->
	    [{<<"set">>, SubEl}];
	{false, false} ->
	    []
    end.

disco_sm_features(empty, From, To, Node, Lang) ->
    disco_sm_features({result, []}, From, To, Node, Lang);
disco_sm_features({result, OtherFeatures},
		  #jid{luser = U, lserver = S},
		  #jid{luser = U, lserver = S}, <<>>, _Lang) ->
    {result, [?NS_MAM_TMP, ?NS_MAM_0, ?NS_MAM_1 | OtherFeatures]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

message_is_archived(true, _C2SState, _Peer, _JID, _Pkt) ->
    true;
message_is_archived(false, C2SState, Peer,
		    #jid{luser = LUser, lserver = LServer}, Pkt) ->
    Res = case gen_mod:get_module_opt(LServer, ?MODULE, assume_mam_usage,
				      fun(if_enabled) -> if_enabled;
					 (on_request) -> on_request;
					 (never) -> never
				      end, never) of
	      if_enabled ->
		  get_prefs(LUser, LServer);
	      on_request ->
		  DBType = gen_mod:db_type(LServer, ?MODULE),
		  cache_tab:lookup(archive_prefs, {LUser, LServer},
				   fun() ->
					   get_prefs(LUser, LServer, DBType)
				   end);
	      never ->
		  error
	  end,
    case Res of
	{ok, Prefs} ->
	    should_archive(strip_my_archived_tag(Pkt, LServer), LServer)
		andalso should_archive_peer(C2SState, Prefs, Peer);
	error ->
	    false
    end.

delete_old_messages(TypeBin, Days) when TypeBin == <<"chat">>;
					TypeBin == <<"groupchat">>;
					TypeBin == <<"all">> ->
    Diff = Days * 24 * 60 * 60 * 1000000,
    TimeStamp = usec_to_now(p1_time_compat:system_time(micro_seconds) - Diff),
    Type = jlib:binary_to_atom(TypeBin),
    {Results, _} =
	lists:foldl(fun(Host, {Results, MnesiaDone}) ->
			    case {gen_mod:db_type(Host, ?MODULE), MnesiaDone} of
				{mnesia, true} ->
				    {Results, true};
				{mnesia, false} ->
				    Res = delete_old_messages(TimeStamp, Type,
							      global, mnesia),
				    {[Res|Results], true};
				{DBType, _} ->
				    Res = delete_old_messages(TimeStamp, Type,
							      Host, DBType),
				    {[Res|Results], MnesiaDone}
			    end
		    end, {[], false}, ?MYHOSTS),
    case lists:filter(fun(Res) -> Res /= ok end, Results) of
	[] -> ok;
	[NotOk|_] -> NotOk
    end;
delete_old_messages(_TypeBin, _Days) ->
    unsupported_type.

delete_old_messages(TimeStamp, Type, global, mnesia) ->
    MS = ets:fun2ms(fun(#archive_msg{timestamp = MsgTS,
				     type = MsgType} = Msg)
			    when MsgTS < TimeStamp,
				 MsgType == Type orelse Type == all ->
			    Msg
		    end),
    OldMsgs = mnesia:dirty_select(archive_msg, MS),
    lists:foreach(fun(Rec) ->
			  ok = mnesia:dirty_delete_object(Rec)
		  end, OldMsgs);
delete_old_messages(_TimeStamp, _Type, _Host, _DBType) ->
    %% TODO
    not_implemented.

%%%===================================================================
%%% Internal functions
%%%===================================================================

process_iq(LServer, #iq{sub_el = #xmlel{attrs = Attrs}} = IQ) ->
    NS = case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	     ?NS_MAM_0 ->
		 ?NS_MAM_0;
	     _ ->
		 ?NS_MAM_1
	 end,
    CommonFields = [#xmlel{name = <<"field">>,
			   attrs = [{<<"type">>, <<"hidden">>},
				    {<<"var">>, <<"FORM_TYPE">>}],
			   children = [#xmlel{name = <<"value">>,
					      children = [{xmlcdata, NS}]}]},
		    #xmlel{name = <<"field">>,
			   attrs = [{<<"type">>, <<"jid-single">>},
				    {<<"var">>, <<"with">>}]},
		    #xmlel{name = <<"field">>,
			   attrs = [{<<"type">>, <<"text-single">>},
				    {<<"var">>, <<"start">>}]},
		    #xmlel{name = <<"field">>,
			   attrs = [{<<"type">>, <<"text-single">>},
				    {<<"var">>, <<"end">>}]}],
    Fields = case gen_mod:db_type(LServer, ?MODULE) of
		 odbc ->
		     WithText = #xmlel{name = <<"field">>,
				       attrs = [{<<"type">>, <<"text-single">>},
						{<<"var">>, <<"withtext">>}]},
		     [WithText|CommonFields];
		 _ ->
		     CommonFields
	     end,
    Form = #xmlel{name = <<"x">>,
		  attrs = [{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"form">>}],
		  children = Fields},
    IQ#iq{type = result,
	  sub_el = [#xmlel{name = <<"query">>,
			   attrs = [{<<"xmlns">>, NS}],
			   children = [Form]}]}.

% Preference setting (both v0.2 & v0.3)
process_iq(#jid{luser = LUser, lserver = LServer},
	   #jid{lserver = LServer},
	   #iq{type = set, lang = Lang, sub_el = #xmlel{name = <<"prefs">>} = SubEl} = IQ) ->
    try {case fxml:get_tag_attr_s(<<"default">>, SubEl) of
	    <<"always">> -> always;
	    <<"never">> -> never;
	    <<"roster">> -> roster
	    end,
	    lists:foldl(
		fun(#xmlel{name = <<"always">>, children = Els}, {A, N}) ->
			{get_jids(Els) ++ A, N};
		    (#xmlel{name = <<"never">>, children = Els}, {A, N}) ->
			{A, get_jids(Els) ++ N};
		    (_, {A, N}) ->
			{A, N}
		end, {[], []}, SubEl#xmlel.children)} of
	{Default, {Always0, Never0}} ->
	    Always = lists:usort(Always0),
	    Never = lists:usort(Never0),
	    case write_prefs(LUser, LServer, LServer, Default, Always, Never) of
		ok ->
		    NewPrefs = prefs_el(Default, Always, Never, IQ#iq.xmlns),
		    IQ#iq{type = result, sub_el = [NewPrefs]};
		_Err ->
		    Txt = <<"Database failure">>,
		    IQ#iq{type = error,
			sub_el = [SubEl, ?ERRT_INTERNAL_SERVER_ERROR(Lang, Txt)]}
	    end
    catch _:_ ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]}
    end;
process_iq(#jid{luser = LUser, lserver = LServer},
	   #jid{lserver = LServer},
	   #iq{type = get, sub_el = #xmlel{name = <<"prefs">>}} = IQ) ->
    Prefs = get_prefs(LUser, LServer),
    PrefsEl = prefs_el(Prefs#archive_prefs.default,
		       Prefs#archive_prefs.always,
		       Prefs#archive_prefs.never,
		       IQ#iq.xmlns),
    IQ#iq{type = result, sub_el = [PrefsEl]};
process_iq(_, _, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.

process_iq(LServer, #jid{luser = LUser} = From, To, IQ, SubEl, Fs, MsgType) ->
    case MsgType of
	chat ->
	    maybe_activate_mam(LUser, LServer);
	{groupchat, _Role, _MUCState} ->
	    ok
    end,
    case catch lists:foldl(
		 fun({<<"start">>, [Data|_]}, {_, End, With, RSM}) ->
			 {{_, _, _} = jlib:datetime_string_to_timestamp(Data),
			  End, With, RSM};
		    ({<<"end">>, [Data|_]}, {Start, _, With, RSM}) ->
			 {Start,
			  {_, _, _} = jlib:datetime_string_to_timestamp(Data),
			  With, RSM};
		    ({<<"with">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End, jid:tolower(jid:from_string(Data)), RSM};
		    ({<<"withtext">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End, {text, Data}, RSM};
		    ({<<"set">>, El}, {Start, End, With, _}) ->
			 {Start, End, With, jlib:rsm_decode(El)};
		    (_, Acc) ->
			 Acc
		 end, {none, [], none, none}, Fs) of
	{'EXIT', _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]};
	{_Start, _End, _With, #rsm_in{index = Index}} when is_integer(Index) ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_FEATURE_NOT_IMPLEMENTED]};
	{Start, End, With, RSM} ->
	    NS = fxml:get_tag_attr_s(<<"xmlns">>, SubEl),
	    select_and_send(LServer, From, To, Start, End,
			    With, limit_max(RSM, NS), IQ, MsgType)
    end.

muc_process_iq(#iq{lang = Lang, sub_el = SubEl} = IQ, MUCState, From, To, Fs) ->
    case may_enter_room(From, MUCState) of
	true ->
	    LServer = MUCState#state.server_host,
	    Role = mod_muc_room:get_role(From, MUCState),
	    process_iq(LServer, From, To, IQ, SubEl, Fs,
		       {groupchat, Role, MUCState});
	false ->
	    Text = <<"Only members may query archives of this room">>,
	    Error = ?ERRT_FORBIDDEN(Lang, Text),
	    IQ#iq{type = error, sub_el = [SubEl, Error]}
    end.

parse_query_v0_2(Query) ->
    lists:flatmap(
      fun (#xmlel{name = <<"start">>} = El) ->
	      [{<<"start">>, [fxml:get_tag_cdata(El)]}];
	  (#xmlel{name = <<"end">>} = El) ->
	      [{<<"end">>, [fxml:get_tag_cdata(El)]}];
	  (#xmlel{name = <<"with">>} = El) ->
	      [{<<"with">>, [fxml:get_tag_cdata(El)]}];
	  (#xmlel{name = <<"withtext">>} = El) ->
	      [{<<"withtext">>, [fxml:get_tag_cdata(El)]}];
	  (#xmlel{name = <<"set">>}) ->
	      [{<<"set">>, Query}];
	  (_) ->
	     []
      end, Query#xmlel.children).

should_archive(#xmlel{name = <<"message">>} = Pkt, LServer) ->
    case fxml:get_attr_s(<<"type">>, Pkt#xmlel.attrs) of
	<<"error">> ->
	    false;
	<<"groupchat">> ->
	    false;
	_ ->
	    case is_resent(Pkt, LServer) of
		true ->
		    false;
		false ->
		    case check_store_hint(Pkt) of
			store ->
			    true;
			no_store ->
			    false;
			none ->
			    case fxml:get_subtag_cdata(Pkt, <<"body">>) of
				<<>> ->
				    %% Empty body
				    false;
				_ ->
				    true
			    end
		    end
	    end
    end;
should_archive(#xmlel{}, _LServer) ->
    false.

strip_my_archived_tag(Pkt, LServer) ->
    NewEls = lists:filter(
	    fun(#xmlel{name = Tag, attrs = Attrs})
			when Tag == <<"archived">>; Tag == <<"stanza-id">> ->
		    case catch jid:nameprep(
			    fxml:get_attr_s(
				<<"by">>, Attrs)) of
			LServer ->
			    false;
			_ ->
			    true
		    end;
		(_) ->
		    true
	    end, Pkt#xmlel.children),
    Pkt#xmlel{children = NewEls}.

strip_x_jid_tags(Pkt) ->
    NewEls = lists:filter(
	      fun(#xmlel{name = <<"x">>} = XEl) ->
		      not lists:any(fun(ItemEl) ->
					    fxml:get_tag_attr(<<"jid">>, ItemEl)
					      /= false
				    end, fxml:get_subtags(XEl, <<"item">>));
		 (_) ->
		      true
	      end, Pkt#xmlel.children),
    Pkt#xmlel{children = NewEls}.

should_archive_peer(C2SState,
		    #archive_prefs{default = Default,
				   always = Always,
				   never = Never},
		    Peer) ->
    LPeer = jid:tolower(Peer),
    case lists:member(LPeer, Always) of
	true ->
	    true;
	false ->
	    case lists:member(LPeer, Never) of
		true ->
		    false;
		false ->
		    case Default of
			always -> true;
			never -> false;
			roster ->
			    case ejabberd_c2s:get_subscription(
				   LPeer, C2SState) of
				both -> true;
				from -> true;
				to -> true;
				_ -> false
			    end
		    end
	    end
    end.

should_archive_muc(Pkt) ->
    case fxml:get_attr_s(<<"type">>, Pkt#xmlel.attrs) of
	<<"groupchat">> ->
	    case check_store_hint(Pkt) of
		store ->
		    true;
		no_store ->
		    false;
		none ->
		    case fxml:get_subtag_cdata(Pkt, <<"body">>) of
			<<>> ->
			    case fxml:get_subtag_cdata(Pkt, <<"subject">>) of
				<<>> ->
				    false;
				_ ->
				    true
			    end;
			_ ->
			    true
		    end
	    end;
	_ ->
	    false
    end.

check_store_hint(Pkt) ->
    case has_store_hint(Pkt) of
	true ->
	    store;
	false ->
	    case has_no_store_hint(Pkt) of
		true ->
		    no_store;
		false ->
		    none
	    end
    end.

has_store_hint(Message) ->
    fxml:get_subtag_with_xmlns(Message, <<"store">>, ?NS_HINTS)
      /= false.

has_no_store_hint(Message) ->
    fxml:get_subtag_with_xmlns(Message, <<"no-store">>, ?NS_HINTS)
      /= false orelse
    fxml:get_subtag_with_xmlns(Message, <<"no-storage">>, ?NS_HINTS)
      /= false orelse
    fxml:get_subtag_with_xmlns(Message, <<"no-permanent-store">>, ?NS_HINTS)
      /= false orelse
    fxml:get_subtag_with_xmlns(Message, <<"no-permanent-storage">>, ?NS_HINTS)
      /= false.

is_resent(Pkt, LServer) ->
    case fxml:get_subtag_with_xmlns(Pkt, <<"stanza-id">>, ?NS_SID_0) of
	#xmlel{attrs = Attrs} ->
	    case fxml:get_attr(<<"by">>, Attrs) of
		{value, LServer} ->
		    true;
		_ ->
		    false
	    end;
	false ->
	    false
    end.

may_enter_room(From,
	       #state{config = #config{members_only = false}} = MUCState) ->
    mod_muc_room:get_affiliation(From, MUCState) /= outcast;
may_enter_room(From, MUCState) ->
    mod_muc_room:is_occupant_or_admin(From, MUCState).

store_msg(C2SState, Pkt, LUser, LServer, Peer, Dir) ->
    Prefs = get_prefs(LUser, LServer),
    case should_archive_peer(C2SState, Prefs, Peer) of
	true ->
	    US = {LUser, LServer},
	    store(Pkt, LServer, US, chat, Peer, <<"">>, Dir,
		  gen_mod:db_type(LServer, ?MODULE));
	false ->
	    pass
    end.

store_muc(MUCState, Pkt, RoomJID, Peer, Nick) ->
    case should_archive_muc(Pkt) of
	true ->
	    LServer = MUCState#state.server_host,
	    {U, S, _} = jid:tolower(RoomJID),
	    store(Pkt, LServer, {U, S}, groupchat, Peer, Nick, recv,
		  gen_mod:db_type(LServer, ?MODULE));
	false ->
	    pass
    end.

store(Pkt, _, {LUser, LServer}, Type, Peer, Nick, _Dir, mnesia) ->
    LPeer = {PUser, PServer, _} = jid:tolower(Peer),
    TS = p1_time_compat:timestamp(),
    ID = jlib:integer_to_binary(now_to_usec(TS)),
    case mnesia:dirty_write(
	   #archive_msg{us = {LUser, LServer},
			id = ID,
			timestamp = TS,
			peer = LPeer,
			bare_peer = {PUser, PServer, <<>>},
			type = Type,
			nick = Nick,
			packet = Pkt}) of
	ok ->
	    {ok, ID};
	Err ->
	    Err
    end;
store(Pkt, LServer, {LUser, LHost}, Type, Peer, Nick, _Dir, odbc) ->
    TSinteger = p1_time_compat:system_time(micro_seconds),
    ID = TS = jlib:integer_to_binary(TSinteger),
    SUser = case Type of
		chat -> LUser;
		groupchat -> jid:to_string({LUser, LHost, <<>>})
	    end,
    BarePeer = jid:to_string(
		 jid:tolower(
		   jid:remove_resource(Peer))),
    LPeer = jid:to_string(
	      jid:tolower(Peer)),
    XML = fxml:element_to_binary(Pkt),
    Body = fxml:get_subtag_cdata(Pkt, <<"body">>),
    case ejabberd_odbc:sql_query(
	    LServer,
	    [<<"insert into archive (username, timestamp, "
		    "peer, bare_peer, xml, txt, kind, nick) values (">>,
		<<"'">>, ejabberd_odbc:escape(SUser), <<"', ">>,
		<<"'">>, TS, <<"', ">>,
		<<"'">>, ejabberd_odbc:escape(LPeer), <<"', ">>,
		<<"'">>, ejabberd_odbc:escape(BarePeer), <<"', ">>,
		<<"'">>, ejabberd_odbc:escape(XML), <<"', ">>,
		<<"'">>, ejabberd_odbc:escape(Body), <<"', ">>,
		<<"'">>, jlib:atom_to_binary(Type), <<"', ">>,
		<<"'">>, ejabberd_odbc:escape(Nick), <<"');">>]) of
	{updated, _} ->
	    {ok, ID};
	Err ->
	    Err
    end.

write_prefs(LUser, LServer, Host, Default, Always, Never) ->
    DBType = case gen_mod:db_type(Host, ?MODULE) of
		 odbc -> {odbc, Host};
		 DB -> DB
	     end,
    Prefs = #archive_prefs{us = {LUser, LServer},
			   default = Default,
			   always = Always,
			   never = Never},
    cache_tab:dirty_insert(
      archive_prefs, {LUser, LServer}, Prefs,
      fun() ->  write_prefs(LUser, LServer, Prefs, DBType) end).

write_prefs(_LUser, _LServer, Prefs, mnesia) ->
    mnesia:dirty_write(Prefs);
write_prefs(LUser, _LServer, #archive_prefs{default = Default,
					   never = Never,
					   always = Always},
	    {odbc, Host}) ->
    SUser = ejabberd_odbc:escape(LUser),
    SDefault = erlang:atom_to_binary(Default, utf8),
    SAlways = ejabberd_odbc:encode_term(Always),
    SNever = ejabberd_odbc:encode_term(Never),
    case update(Host, <<"archive_prefs">>,
		[<<"username">>, <<"def">>, <<"always">>, <<"never">>],
		[SUser, SDefault, SAlways, SNever],
		[<<"username='">>, SUser, <<"'">>]) of
	{updated, _} ->
	    ok;
	Err ->
	    Err
    end.

get_prefs(LUser, LServer) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Res = cache_tab:lookup(archive_prefs, {LUser, LServer},
			   fun() -> get_prefs(LUser, LServer,
					      DBType)
			   end),
    case Res of
	{ok, Prefs} ->
	    Prefs;
	error ->
	    ActivateOpt = gen_mod:get_module_opt(
			    LServer, ?MODULE, request_activates_archiving,
			    fun(B) when is_boolean(B) -> B end, false),
	    case ActivateOpt of
		true ->
		    #archive_prefs{us = {LUser, LServer}, default = never};
		false ->
		    Default = gen_mod:get_module_opt(
				LServer, ?MODULE, default,
				fun(always) -> always;
				   (never) -> never;
				   (roster) -> roster
				end, never),
		    #archive_prefs{us = {LUser, LServer}, default = Default}
	    end
    end.

get_prefs(LUser, LServer, mnesia) ->
    case mnesia:dirty_read(archive_prefs, {LUser, LServer}) of
	[Prefs] ->
	    {ok, Prefs};
	_ ->
	    error
    end;
get_prefs(LUser, LServer, odbc) ->
    case ejabberd_odbc:sql_query(
	   LServer,
	   [<<"select def, always, never from archive_prefs ">>,
	    <<"where username='">>,
	    ejabberd_odbc:escape(LUser), <<"';">>]) of
	{selected, _, [[SDefault, SAlways, SNever]]} ->
	    Default = erlang:binary_to_existing_atom(SDefault, utf8),
	    Always = ejabberd_odbc:decode_term(SAlways),
	    Never = ejabberd_odbc:decode_term(SNever),
	    {ok, #archive_prefs{us = {LUser, LServer},
		    default = Default,
		    always = Always,
		    never = Never}};
	_ ->
	    error
    end.

prefs_el(Default, Always, Never, NS) ->
    Default1 = jlib:atom_to_binary(Default),
    JFun = fun(L) ->
		   [#xmlel{name = <<"jid">>,
			   children = [{xmlcdata, jid:to_string(J)}]}
		    || J <- L]
	   end,
    Always1 = #xmlel{name = <<"always">>,
		     children = JFun(Always)},
    Never1 = #xmlel{name = <<"never">>,
		    children = JFun(Never)},
    #xmlel{name = <<"prefs">>,
	   attrs = [{<<"xmlns">>, NS},
		    {<<"default">>, Default1}],
	   children = [Always1, Never1]}.

maybe_activate_mam(LUser, LServer) ->
    ActivateOpt = gen_mod:get_module_opt(LServer, ?MODULE,
					 request_activates_archiving,
					 fun(B) when is_boolean(B) -> B end,
					 false),
    case ActivateOpt of
	true ->
	    Res = cache_tab:lookup(archive_prefs, {LUser, LServer},
				   fun() ->
					   get_prefs(LUser, LServer,
						     gen_mod:db_type(LServer,
								     ?MODULE))
				   end),
	    case Res of
		{ok, _Prefs} ->
		    ok;
		error ->
		    Default = gen_mod:get_module_opt(LServer, ?MODULE, default,
						     fun(always) -> always;
							(never) -> never;
							(roster) -> roster
						     end, never),
		    write_prefs(LUser, LServer, LServer, Default, [], [])
	    end;
	false ->
	    ok
    end.

select_and_send(LServer, From, To, Start, End, With, RSM, IQ, MsgType) ->
    DBType = case gen_mod:db_type(LServer, ?MODULE) of
		 odbc -> {odbc, LServer};
		 DB -> DB
	     end,
    select_and_send(LServer, From, To, Start, End, With, RSM, IQ,
		    MsgType, DBType).

select_and_send(LServer, From, To, Start, End, With, RSM, IQ, MsgType, DBType) ->
    {Msgs, IsComplete, Count} = select_and_start(LServer, From, To, Start, End,
						 With, RSM, MsgType, DBType),
    SortedMsgs = lists:keysort(2, Msgs),
    send(From, To, SortedMsgs, RSM, Count, IsComplete, IQ).

select_and_start(LServer, From, To, Start, End, With, RSM, MsgType, DBType) ->
    case MsgType of
	chat ->
	    select(LServer, From, From, Start, End, With, RSM, MsgType, DBType);
	{groupchat, _Role, _MUCState} ->
	    select(LServer, From, To, Start, End, With, RSM, MsgType, DBType)
    end.

select(_LServer, JidRequestor, JidArchive, Start, End, _With, RSM,
       {groupchat, _Role, #state{config = #config{mam = false},
				 history = History}} = MsgType,
       _DBType) ->
    #lqueue{len = L, queue = Q} = History,
    {Msgs0, _} =
	lists:mapfoldl(
	  fun({Nick, Pkt, _HaveSubject, UTCDateTime, _Size}, I) ->
		  Now = datetime_to_now(UTCDateTime, I),
		  TS = now_to_usec(Now),
		  case match_interval(Now, Start, End) and
		      match_rsm(Now, RSM) of
		      true ->
			  {[{jlib:integer_to_binary(TS), TS,
			     msg_to_el(#archive_msg{
					  type = groupchat,
					  timestamp = Now,
					  peer = undefined,
					  nick = Nick,
					  packet = Pkt},
				       MsgType, JidRequestor, JidArchive)}],
			   I+1};
		      false ->
			  {[], I+1}
		  end
	  end, 0, queue:to_list(Q)),
    Msgs = lists:flatten(Msgs0),
    case RSM of
	#rsm_in{max = Max, direction = before} ->
	    {NewMsgs, IsComplete} = filter_by_max(lists:reverse(Msgs), Max),
	    {NewMsgs, IsComplete, L};
	#rsm_in{max = Max} ->
	    {NewMsgs, IsComplete} = filter_by_max(Msgs, Max),
	    {NewMsgs, IsComplete, L};
	_ ->
	    {Msgs, true, L}
    end;
select(_LServer, JidRequestor,
       #jid{luser = LUser, lserver = LServer} = JidArchive,
       Start, End, With, RSM, MsgType, mnesia) ->
    MS = make_matchspec(LUser, LServer, Start, End, With),
    Msgs = mnesia:dirty_select(archive_msg, MS),
    SortedMsgs = lists:keysort(#archive_msg.timestamp, Msgs),
    {FilteredMsgs, IsComplete} = filter_by_rsm(SortedMsgs, RSM),
    Count = length(Msgs),
    {lists:map(
       fun(Msg) ->
	       {Msg#archive_msg.id,
		jlib:binary_to_integer(Msg#archive_msg.id),
		msg_to_el(Msg, MsgType, JidRequestor, JidArchive)}
       end, FilteredMsgs), IsComplete, Count};
select(LServer, JidRequestor, #jid{luser = LUser} = JidArchive,
       Start, End, With, RSM, MsgType, {odbc, Host}) ->
    User = case MsgType of
	       chat -> LUser;
	       {groupchat, _Role, _MUCState} -> jid:to_string(JidArchive)
	   end,
    {Query, CountQuery} = make_sql_query(User, LServer,
					 Start, End, With, RSM),
    % TODO from XEP-0313 v0.2: "To conserve resources, a server MAY place a
    % reasonable limit on how many stanzas may be pushed to a client in one
    % request. If a query returns a number of stanzas greater than this limit
    % and the client did not specify a limit using RSM then the server should
    % return a policy-violation error to the client." We currently don't do this
    % for v0.2 requests, but we do limit #rsm_in.max for v0.3 and newer.
    case {ejabberd_odbc:sql_query(Host, Query),
	  ejabberd_odbc:sql_query(Host, CountQuery)} of
	{{selected, _, Res}, {selected, _, [[Count]]}} ->
	    {Max, Direction} = case RSM of
				   #rsm_in{max = M, direction = D} -> {M, D};
				   _ -> {undefined, undefined}
			       end,
	    {Res1, IsComplete} =
		if Max >= 0 andalso Max /= undefined andalso length(Res) > Max ->
			if Direction == before ->
				{lists:nthtail(1, Res), false};
			   true ->
				{lists:sublist(Res, Max), false}
			end;
		   true ->
			{Res, true}
		end,
	    {lists:flatmap(
	       fun([TS, XML, PeerBin, Kind, Nick]) ->
		       try
			   #xmlel{} = El = fxml_stream:parse_element(XML),
			   Now = usec_to_now(jlib:binary_to_integer(TS)),
			   PeerJid = jid:tolower(jid:from_string(PeerBin)),
			   T = case Kind of
				   <<"">> -> chat;
				   null -> chat;
				   _ -> jlib:binary_to_atom(Kind)
			       end,
			   [{TS, jlib:binary_to_integer(TS),
			     msg_to_el(#archive_msg{timestamp = Now,
						    packet = El,
						    type = T,
						    nick = Nick,
						    peer = PeerJid},
				       MsgType, JidRequestor, JidArchive)}]
		       catch _:Err ->
			       ?ERROR_MSG("failed to parse data from SQL: ~p. "
					  "The data was: "
					  "timestamp = ~s, xml = ~s, "
					  "peer = ~s, kind = ~s, nick = ~s",
					  [Err, TS, XML, PeerBin, Kind, Nick]),
			       []
		       end
	       end, Res1), IsComplete, jlib:binary_to_integer(Count)};
	_ ->
	    {[], false, 0}
    end.

msg_to_el(#archive_msg{timestamp = TS, packet = Pkt1, nick = Nick, peer = Peer},
	  MsgType, JidRequestor, #jid{lserver = LServer} = JidArchive) ->
    Pkt2 = maybe_update_from_to(Pkt1, JidRequestor, JidArchive, Peer, MsgType,
				Nick),
    Pkt3 = #xmlel{name = <<"forwarded">>,
		  attrs = [{<<"xmlns">>, ?NS_FORWARD}],
		  children = [fxml:replace_tag_attr(
				<<"xmlns">>, <<"jabber:client">>, Pkt2)]},
    jlib:add_delay_info(Pkt3, LServer, TS).

maybe_update_from_to(#xmlel{children = Els} = Pkt, JidRequestor, JidArchive,
		     Peer, {groupchat, Role,
			    #state{config = #config{anonymous = Anon}}},
		     Nick) ->
    ExposeJID = case {Peer, JidRequestor} of
		    {undefined, _JidRequestor} ->
			false;
		    {{U, S, _R}, #jid{luser = U, lserver = S}} ->
			true;
		    {_Peer, _JidRequestor} when not Anon; Role == moderator ->
			true;
		    {_Peer, _JidRequestor} ->
			false
		end,
    Items = case ExposeJID of
		true ->
		    [#xmlel{name = <<"x">>,
			    attrs = [{<<"xmlns">>, ?NS_MUC_USER}],
			    children =
				[#xmlel{name = <<"item">>,
					attrs = [{<<"jid">>,
						  jid:to_string(Peer)}]}]}];
		false ->
		    []
	    end,
    Pkt1 = Pkt#xmlel{children = Items ++ Els},
    Pkt2 = jlib:replace_from(jid:replace_resource(JidArchive, Nick), Pkt1),
    jlib:remove_attr(<<"to">>, Pkt2);
maybe_update_from_to(Pkt, _JidRequestor, _JidArchive, _Peer, chat, _Nick) ->
    Pkt.

is_bare_copy(#jid{luser = U, lserver = S, lresource = R}, To) ->
    PrioRes = ejabberd_sm:get_user_present_resources(U, S),
    MaxRes = case catch lists:max(PrioRes) of
		 {_Prio, Res} when is_binary(Res) ->
		     Res;
		 _ ->
		     undefined
	     end,
    IsBareTo = case To of
		   #jid{lresource = <<"">>} ->
		       true;
		   #jid{lresource = LRes} ->
		       %% Unavailable resources are handled like bare JIDs.
		       lists:keyfind(LRes, 2, PrioRes) =:= false
	       end,
    case {IsBareTo, R} of
	{true, MaxRes} ->
	    ?DEBUG("Recipient of message to bare JID has top priority: ~s@~s/~s",
		   [U, S, R]),
	    false;
	{true, _R} ->
	    %% The message was sent to our bare JID, and we currently have
	    %% multiple resources with the same highest priority, so the session
	    %% manager routes the message to each of them. We store the message
	    %% only from the resource where R equals MaxRes.
	    ?DEBUG("Additional recipient of message to bare JID: ~s@~s/~s",
		   [U, S, R]),
	    true;
	{false, _R} ->
	    false
    end.

send(From, To, Msgs, RSM, Count, IsComplete, #iq{sub_el = SubEl} = IQ) ->
    QID = fxml:get_tag_attr_s(<<"queryid">>, SubEl),
    NS = fxml:get_tag_attr_s(<<"xmlns">>, SubEl),
    QIDAttr = if QID /= <<>> ->
		      [{<<"queryid">>, QID}];
		 true ->
		    []
	      end,
    CompleteAttr = if NS == ?NS_MAM_TMP ->
			   [];
		      NS == ?NS_MAM_0; NS == ?NS_MAM_1 ->
			   [{<<"complete">>, jlib:atom_to_binary(IsComplete)}]
		   end,
    Els = lists:map(
	    fun({ID, _IDInt, El}) ->
		    #xmlel{name = <<"message">>,
			   children = [#xmlel{name = <<"result">>,
					      attrs = [{<<"xmlns">>, NS},
						       {<<"id">>, ID}|QIDAttr],
					      children = [El]}]}
	    end, Msgs),
    RSMOut = make_rsm_out(Msgs, RSM, Count, QIDAttr ++ CompleteAttr, NS),
    if NS == ?NS_MAM_TMP; NS == ?NS_MAM_1 ->
	    lists:foreach(
	      fun(El) ->
		      ejabberd_router:route(To, From, El)
	      end, Els),
	    IQ#iq{type = result, sub_el = RSMOut};
       NS == ?NS_MAM_0 ->
	    ejabberd_router:route(
	      To, From, jlib:iq_to_xml(IQ#iq{type = result, sub_el = []})),
	    lists:foreach(
	      fun(El) ->
		      ejabberd_router:route(To, From, El)
	      end, Els),
	    ejabberd_router:route(
	      To, From, #xmlel{name = <<"message">>,
			       children = RSMOut}),
	    ignore
    end.


make_rsm_out([], _, Count, Attrs, NS) ->
    Tag = if NS == ?NS_MAM_TMP -> <<"query">>;
	     true -> <<"fin">>
	  end,
    [#xmlel{name = Tag, attrs = [{<<"xmlns">>, NS}|Attrs],
	    children = jlib:rsm_encode(#rsm_out{count = Count})}];
make_rsm_out([{FirstID, _, _}|_] = Msgs, _, Count, Attrs, NS) ->
    {LastID, _, _} = lists:last(Msgs),
    Tag = if NS == ?NS_MAM_TMP -> <<"query">>;
	     true -> <<"fin">>
	  end,
    [#xmlel{name = Tag, attrs = [{<<"xmlns">>, NS}|Attrs],
	    children = jlib:rsm_encode(
			 #rsm_out{first = FirstID, count = Count,
				  last = LastID})}].

filter_by_rsm(Msgs, none) ->
    {Msgs, true};
filter_by_rsm(_Msgs, #rsm_in{max = Max}) when Max < 0 ->
    {[], true};
filter_by_rsm(Msgs, #rsm_in{max = Max, direction = Direction, id = ID}) ->
    NewMsgs = case Direction of
		  aft when ID /= <<"">> ->
		      lists:filter(
			fun(#archive_msg{id = I}) ->
				?BIN_GREATER_THAN(I, ID)
			end, Msgs);
		  before when ID /= <<"">> ->
		      lists:foldl(
			fun(#archive_msg{id = I} = Msg, Acc)
				when ?BIN_LESS_THAN(I, ID) ->
				[Msg|Acc];
			   (_, Acc) ->
				Acc
			end, [], Msgs);
		  before when ID == <<"">> ->
		      lists:reverse(Msgs);
		  _ ->
		      Msgs
	      end,
    filter_by_max(NewMsgs, Max).

filter_by_max(Msgs, undefined) ->
    {Msgs, true};
filter_by_max(Msgs, Len) when is_integer(Len), Len >= 0 ->
    {lists:sublist(Msgs, Len), length(Msgs) =< Len};
filter_by_max(_Msgs, _Junk) ->
    {[], true}.

limit_max(RSM, ?NS_MAM_TMP) ->
    RSM; % XEP-0313 v0.2 doesn't require clients to support RSM.
limit_max(#rsm_in{max = Max} = RSM, _NS) when not is_integer(Max) ->
    RSM#rsm_in{max = ?DEF_PAGE_SIZE};
limit_max(#rsm_in{max = Max} = RSM, _NS) when Max > ?MAX_PAGE_SIZE ->
    RSM#rsm_in{max = ?MAX_PAGE_SIZE};
limit_max(RSM, _NS) ->
    RSM.

match_interval(Now, Start, End) ->
    (Now >= Start) and (Now =< End).

match_rsm(Now, #rsm_in{id = ID, direction = aft}) when ID /= <<"">> ->
    Now1 = (catch usec_to_now(jlib:binary_to_integer(ID))),
    Now > Now1;
match_rsm(Now, #rsm_in{id = ID, direction = before}) when ID /= <<"">> ->
    Now1 = (catch usec_to_now(jlib:binary_to_integer(ID))),
    Now < Now1;
match_rsm(_Now, _) ->
    true.

make_matchspec(LUser, LServer, Start, End, {_, _, <<>>} = With) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
		       us = US,
		       bare_peer = BPeer} = Msg)
	    when Start =< TS, End >= TS,
		 US == {LUser, LServer},
		 BPeer == With ->
	      Msg
      end);
make_matchspec(LUser, LServer, Start, End, {_, _, _} = With) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
		       us = US,
		       peer = Peer} = Msg)
	    when Start =< TS, End >= TS,
		 US == {LUser, LServer},
		 Peer == With ->
	      Msg
      end);
make_matchspec(LUser, LServer, Start, End, none) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
		       us = US,
		       peer = Peer} = Msg)
	    when Start =< TS, End >= TS,
		 US == {LUser, LServer} ->
	      Msg
      end).

make_sql_query(User, LServer, Start, End, With, RSM) ->
    {Max, Direction, ID} = case RSM of
	#rsm_in{} ->
	    {RSM#rsm_in.max,
		RSM#rsm_in.direction,
		RSM#rsm_in.id};
	none ->
	    {none, none, <<>>}
    end,
    ODBCType = ejabberd_config:get_option(
		 {odbc_type, LServer},
		 ejabberd_odbc:opt_type(odbc_type)),
    LimitClause = if is_integer(Max), Max >= 0, ODBCType /= mssql ->
			  [<<" limit ">>, jlib:integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    TopClause = if is_integer(Max), Max >= 0, ODBCType == mssql ->
			  [<<" TOP ">>, jlib:integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    WithClause = case With of
		     {text, <<>>} ->
			 [];
		     {text, Txt} ->
			 [<<" and match (txt) against ('">>,
			  ejabberd_odbc:escape(Txt), <<"')">>];
		     {_, _, <<>>} ->
			 [<<" and bare_peer='">>,
			  ejabberd_odbc:escape(jid:to_string(With)),
			  <<"'">>];
		     {_, _, _} ->
			 [<<" and peer='">>,
			  ejabberd_odbc:escape(jid:to_string(With)),
			  <<"'">>];
		     none ->
			 []
		 end,
    PageClause = case catch jlib:binary_to_integer(ID) of
		     I when is_integer(I), I >= 0 ->
			 case Direction of
			     before ->
				 [<<" AND timestamp < ">>, ID];
			     aft ->
				 [<<" AND timestamp > ">>, ID];
			     _ ->
				 []
			 end;
		     _ ->
			 []
		 end,
    StartClause = case Start of
		      {_, _, _} ->
			  [<<" and timestamp >= ">>,
			   jlib:integer_to_binary(now_to_usec(Start))];
		      _ ->
			  []
		  end,
    EndClause = case End of
		    {_, _, _} ->
			[<<" and timestamp <= ">>,
			 jlib:integer_to_binary(now_to_usec(End))];
		    _ ->
			[]
		end,
    SUser = ejabberd_odbc:escape(User),

    Query = [<<"SELECT ">>, TopClause, <<" timestamp, xml, peer, kind, nick"
	      " FROM archive WHERE username='">>,
	     SUser, <<"'">>, WithClause, StartClause, EndClause,
	     PageClause],

    QueryPage =
	case Direction of
	    before ->
		% ID can be empty because of
		% XEP-0059: Result Set Management
		% 2.5 Requesting the Last Page in a Result Set
		[<<"SELECT timestamp, xml, peer, kind, nick FROM (">>, Query,
		 <<" ORDER BY timestamp DESC ">>,
		 LimitClause, <<") AS t ORDER BY timestamp ASC;">>];
	    _ ->
		[Query, <<" ORDER BY timestamp ASC ">>,
		 LimitClause, <<";">>]
	end,
    {QueryPage,
     [<<"SELECT COUNT(*) FROM archive WHERE username='">>,
      SUser, <<"'">>, WithClause, StartClause, EndClause, <<";">>]}.

now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.

usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

datetime_to_now(DateTime, USecs) ->
    Seconds = calendar:datetime_to_gregorian_seconds(DateTime) -
	calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    {Seconds div 1000000, Seconds rem 1000000, USecs}.

get_jids(Els) ->
    lists:flatmap(
      fun(#xmlel{name = <<"jid">>} = El) ->
	      J = jid:from_string(fxml:get_tag_cdata(El)),
	      [jid:tolower(jid:remove_resource(J)),
	       jid:tolower(J)];
	 (_) ->
	      []
      end, Els).

update(LServer, Table, Fields, Vals, Where) ->
    UPairs = lists:zipwith(fun (A, B) ->
				   <<A/binary, "='", B/binary, "'">>
			   end,
			   Fields, Vals),
    case ejabberd_odbc:sql_query(LServer,
				 [<<"update ">>, Table, <<" set ">>,
				  join(UPairs, <<", ">>), <<" where ">>, Where,
				  <<";">>])
	of
	{updated, 1} -> {updated, 1};
	_ ->
	    ejabberd_odbc:sql_query(LServer,
				    [<<"insert into ">>, Table, <<"(">>,
				     join(Fields, <<", ">>), <<") values ('">>,
				     join(Vals, <<"', '">>), <<"');">>])
    end.

%% Almost a copy of string:join/2.
join([], _Sep) -> [];
join([H | T], Sep) -> [H, [[Sep, X] || X <- T]].

get_commands_spec() ->
    [#ejabberd_commands{name = delete_old_mam_messages, tags = [purge],
			desc = "Delete MAM messages older than DAYS",
			longdesc = "Valid message TYPEs: "
				   "\"chat\", \"groupchat\", \"all\".",
			module = ?MODULE, function = delete_old_messages,
			args = [{type, binary}, {days, integer}],
			result = {res, rescode}}].

mod_opt_type(assume_mam_usage) ->
    fun(if_enabled) -> if_enabled;
       (on_request) -> on_request;
       (never) -> never
    end;
mod_opt_type(cache_life_time) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(cache_size) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(db_type) -> fun gen_mod:v_db/1;
mod_opt_type(default) ->
    fun (always) -> always;
	(never) -> never;
	(roster) -> roster
    end;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(request_activates_archiving) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(_) ->
    [assume_mam_usage, cache_life_time, cache_size, db_type, default, iqdisc,
     request_activates_archiving].
