%%
%% Copyright (c) 2018, 2019 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% SIP Headers Helpers
%%

-module(ersip_siphdr).

-export([all_known_headers/0,
         parse_header/2,
         copy_headers/3,
         copy_header/3,
         set_header/3,
         remove_header/2,
         set_raw_header/2
        ]).
-export_type([known_header/0]).

%%%===================================================================
%%% Types
%%%===================================================================


-record(descr, {required     :: header_required(),
                may_appear   :: once | multiple,
                parse_fun    :: parse_fun_type(),
                assemble_fun :: undefined | assemble_fun_type()
               }).
-type descr() :: #descr{}.

-type parse_fun_type() :: fun((ersip_hdr:header()) -> parse_fun_result()).
-type parse_fun_result() :: {ok, Value :: term()}
                          | {error, Reason :: term()}.
-type assemble_fun_type() :: fun((Name :: binary(), Value :: term()) -> ersip_hdr:header()).
-type known_header() :: ersip_hnames:known_header().

%%%===================================================================
%%% API
%%%===================================================================

all_known_headers() ->
    ersip_hnames:all_known_headers().

-spec parse_header(known_header(), ersip_sipmsg:sipmsg()) -> ValueOrError when
      ValueOrError :: {ok, term()}
                    | {error, term()}.
parse_header(HdrAtom, Msg) when is_atom(HdrAtom) ->
    Descr = header_descr(HdrAtom),
    case get_header(HdrAtom, Descr, Msg) of
        {ok, no_header} ->
            {ok, no_header};
        {ok, Hdr} ->
            parse_header_by_descr(Descr, Hdr);
        {error, _} = Error ->
            Error
    end.

-spec copy_header(Header, SrcSipMsg, DstSipMsg) -> NewDstSipMsg when
      Header       :: ersip_hnames:name_forms(),
      SrcSipMsg    :: ersip_sipmsg:sipmsg(),
      DstSipMsg    :: ersip_sipmsg:sipmsg(),
      NewDstSipMsg :: ersip_sipmsg:sipmsg().
copy_header(HdrAtom, SrcMsg, DstMsg0) when is_atom(HdrAtom) ->
    DstMsg1 =
        case maps:find(HdrAtom, ersip_sipmsg:headers(SrcMsg)) of
            {ok, Value} ->
                DstHeaders0 = ersip_sipmsg:headers(DstMsg0),
                ersip_sipmsg:set_headers(DstHeaders0#{HdrAtom => Value}, DstMsg0);
            error->
                DstMsg0
        end,
    copy_raw_header(HdrAtom, SrcMsg, DstMsg1);
copy_header(HdrName, SrcMsg, DstMsg) when is_binary(HdrName) ->
    HdrKey = ersip_hnames:make_key(HdrName),
    copy_header(HdrKey, SrcMsg, DstMsg);
copy_header({hdr_key, _} = HdrKey, SrcMsg, DstMsg) ->
    case ersip_hnames:known_header_form(HdrKey) of
        {ok, HdrAtom} ->
            copy_header(HdrAtom, SrcMsg, DstMsg);
        not_found ->
            copy_raw_header(HdrKey, SrcMsg, DstMsg)
    end.

-spec copy_headers(HeaderList, SrcSipMsg, DstSipMsg) -> NewDstSipMsg when
      HeaderList   :: [known_header() | binary()],
      SrcSipMsg    :: ersip_sipmsg:sipmsg(),
      DstSipMsg    :: ersip_sipmsg:sipmsg(),
      NewDstSipMsg :: ersip_sipmsg:sipmsg().
copy_headers(HeaderList, SrcSipMsg, DstSipMsg) ->
    lists:foldl(fun(Header, CurMsg) ->
                        copy_header(Header, SrcSipMsg, CurMsg)
                end,
                DstSipMsg,
                HeaderList).

-spec set_header(known_header(), Value :: term(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
set_header(Header, Value, SipMsg) when is_atom(Header) ->
    #descr{assemble_fun = AssembleF} = header_descr(Header),
    PrintName  = ersip_hnames:print_form(Header),
    OldHeaders = ersip_sipmsg:headers(SipMsg),
    OldRawMsg  = ersip_sipmsg:raw_message(SipMsg),

    RawHdr     = AssembleF(PrintName, Value),
    IsDeleted  = ersip_hdr:is_empty(RawHdr),
    NewHeaders =
        case IsDeleted of
            true ->
                maps:remove(Header, OldHeaders);
            false ->
                OldHeaders#{Header => Value}
        end,
    NewRawMsg  =
        case IsDeleted of
            true ->
                ersip_msg:del_header(RawHdr, OldRawMsg);
            false ->
                ersip_msg:set_header(RawHdr, OldRawMsg)
        end,

    SipMsg1    = ersip_sipmsg:set_headers(NewHeaders, SipMsg),
    SipMsg2    = ersip_sipmsg:set_raw_message(NewRawMsg, SipMsg1),
    SipMsg2.

%% @doc Set header to specified value. If this value is already parsed
%% then also updates parsed cached value.
-spec set_raw_header(ersip_hdr:header(), ersip_sipmsg:sipmsg()) -> {ok, ersip_sipmsg:sipmsg()} | {error, term()}.
set_raw_header(RawHdr, SipMsg0) ->
    NewRawMsg = ersip_msg:set_header(RawHdr, ersip_sipmsg:raw_message(SipMsg0)),
    SipMsg = ersip_sipmsg:set_raw_message(NewRawMsg, SipMsg0),
    case ersip_hnames:known_header_form(ersip_hdr:make_key(RawHdr)) of
        not_found ->
            %% For unknown headers: set only raw header and that is it.
            {ok, SipMsg};
        {ok, HdrAtom} ->
            %% For known headers: set only raw header and try to parse
            %% it if it is already parsed
            ParsedHeaders = ersip_sipmsg:headers(SipMsg),
            case maps:find(HdrAtom, ParsedHeaders) of
                {ok, _} ->
                    ParsedHeaders1 = maps:remove(HdrAtom, ParsedHeaders),
                    ersip_sipmsg:parse(ersip_sipmsg:set_headers(ParsedHeaders1, SipMsg), [HdrAtom]);
                error ->
                    {ok, SipMsg}
            end
    end.

-spec remove_header(ersip_hnames:name_forms(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
remove_header(Header, SipMsg) when is_atom(Header) ->
    OldHeaders = ersip_sipmsg:headers(SipMsg),
    OldRawMsg  = ersip_sipmsg:raw_message(SipMsg),

    RawHdr = ersip_hdr:new(Header),

    NewHeaders = maps:remove(Header, OldHeaders),
    NewRawMsg = ersip_msg:del_header(RawHdr, OldRawMsg),

    SipMsg1 = ersip_sipmsg:set_headers(NewHeaders, SipMsg),
    SipMsg2 = ersip_sipmsg:set_raw_message(NewRawMsg, SipMsg1),
    SipMsg2;
remove_header(HdrName, SipMsg) when is_binary(HdrName) ->
    HdrKey = ersip_hdr:make_key(HdrName),
    remove_header(HdrKey, SipMsg);
remove_header({hdr_key, _} = HKey, SipMsg) ->
    case ersip_hnames:known_header_form(HKey) of
        {ok, HdrAtom} ->
            remove_header(HdrAtom, SipMsg);
        not_found ->
            OldRawMsg = ersip_sipmsg:raw_message(SipMsg),
            NewRawMsg = ersip_msg:del_header(HKey, OldRawMsg),
            ersip_sipmsg:set_raw_message(NewRawMsg, SipMsg)
    end.

%%%===================================================================
%%% Internal implementation
%%%===================================================================


-type header_required() :: all        %% Header required for all requests/responses
                         | optional   %% Header is optional for all requests/responses
                         | with_body  %% Header required if body is not empty
                         | requests   %% Header is required in requests
                         | {requests, [ersip_method:method()]}. %% Header is required for defined method(s)

-record(required_essentials, {type     :: ersip_msg:type(),
                              method   :: ersip_method:method(),
                              status   :: undefined | ersip_status:code(),
                              has_body :: boolean()
                             }).
-type required_essentials() :: #required_essentials{}.

-spec parse_header_by_descr(descr(), ersip_hdr:header()) -> Result when
      Result :: {ok, Value :: term()}
              | {error, term()}.
parse_header_by_descr(#descr{parse_fun = F}, Hdr) ->
    F(Hdr).

-spec get_header(known_header(), descr(), ersip_sipmsg:sipmsg()) -> Result when
      Result :: {ok, ersip_hdr:header()}
              | {ok, no_header}
              | {error, {no_required_header, binary()}}
              | {error, {duplicated_header, binary()}}.
get_header(HdrAtom, #descr{} = D, SipMsg) ->
    HdrKey = ersip_hnames:make_known_key(HdrAtom),
    Hdr = ersip_msg:get(HdrKey, ersip_sipmsg:raw_message(SipMsg)),
    case ersip_hdr:is_empty(Hdr) of
        true ->
            Required = is_required(SipMsg, D#descr.required),
            case Required of
                true ->
                    {error, {no_required_header, ersip_hnames:print_form(HdrKey)}};
                false ->
                    {ok, no_header}
            end;
        false ->
            case D#descr.may_appear of
                multiple ->
                    {ok, Hdr};
                once ->
                    case ersip_hdr:raw_values(Hdr) of
                        [_] ->
                            {ok, Hdr};
                        [_| _] ->
                            {error, {duplicated_header, ersip_hnames:print_form(HdrKey)}}
                    end
            end
    end.

-spec is_required(ersip_sipmsg:sipmsg() | required_essentials(), header_required()) -> boolean().
is_required(_, all) ->
    true;
is_required(_, optional) ->
    false;
is_required(#required_essentials{type = request}, requests) ->
    true;
is_required(#required_essentials{type = request, method = M}, {requests, Methods}) ->
    lists:member(M, Methods);
is_required(#required_essentials{has_body = true}, with_body) ->
    true;
is_required(#required_essentials{}, _) ->
    false;
is_required(SipMsg, R) ->
    is_required(required_essentials(SipMsg), R).

-spec required_essentials(ersip_sipmsg:sipmsg()) -> required_essentials().
required_essentials(SipMsg) ->
    Type = ersip_sipmsg:type(SipMsg),
    #required_essentials{
       type     = Type,
       method   = ersip_sipmsg:method(SipMsg),
       status   = ersip_sipmsg:status(SipMsg),
       has_body = ersip_sipmsg:has_body(SipMsg)
      }.

-spec copy_raw_header(HeaderName, SrcSipMsg, DstSipMsg) -> NewDstSipMsg when
      HeaderName   :: ersip_hnames:name_forms(),
      SrcSipMsg    :: ersip_sipmsg:sipmsg(),
      DstSipMsg    :: ersip_sipmsg:sipmsg(),
      NewDstSipMsg :: ersip_sipmsg:sipmsg().
copy_raw_header(Header, SrcSipMsg, DstSipMsg) ->
    Key = ersip_hnames:make_key(Header),
    SrcRawMsg = ersip_sipmsg:raw_message(SrcSipMsg),
    SrcH = ersip_msg:get(Key, SrcRawMsg),
    DstRawMsg = ersip_sipmsg:raw_message(DstSipMsg),
    NewDstRawMsg = ersip_msg:set_header(SrcH, DstRawMsg),
    ersip_sipmsg:set_raw_message(NewDstRawMsg, DstSipMsg).

%%%
%%% Headers description
%%%
-spec header_descr(known_header()) -> #descr{}.
header_descr(from) ->
    #descr{required     = all,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_fromto:parse/1,
           assemble_fun = fun ersip_hdr_fromto:build/2
          };
header_descr(to) ->
    #descr{required     = all,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_fromto:parse/1,
           assemble_fun = fun ersip_hdr_fromto:build/2
          };
header_descr(cseq) ->
    #descr{required     = all,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_cseq:parse/1,
           assemble_fun = fun ersip_hdr_cseq:build/2
          };
header_descr(callid) ->
    #descr{required     = all,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_callid:parse/1,
           assemble_fun = fun ersip_hdr_callid:build/2
          };
header_descr(maxforwards) ->
    #descr{required     = optional, %% It was optional in RFC2543
           may_appear   = once,
           parse_fun    = fun ersip_hdr_maxforwards:parse/1,
           assemble_fun = fun ersip_hdr_maxforwards:build/2
          };
header_descr(topmost_via) ->
    %% Note We trim Via header on connection receive so responses on
    %% UA does not contain Via.
    #descr{required     = requests,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_via:topmost_via/1,
           assemble_fun = undefined
          };
header_descr(content_type) ->
    #descr{required     = with_body,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_content_type:parse/1,
           assemble_fun = fun ersip_hdr_content_type:build/2
          };
header_descr(route) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_route:parse/1,
           assemble_fun = fun ersip_hdr_route:build/2
          };
header_descr(record_route) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_route:parse/1,
           assemble_fun = fun ersip_hdr_route:build/2
          };
header_descr(allow) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_allow:parse/1,
           assemble_fun = fun ersip_hdr_allow:build/2
          };
header_descr(supported) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_opttag_list:parse/1,
           assemble_fun = fun ersip_hdr_opttag_list:build/2
          };
header_descr(unsupported) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_opttag_list:parse/1,
           assemble_fun = fun ersip_hdr_opttag_list:build/2
          };
header_descr(require) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_opttag_list:parse/1,
           assemble_fun = fun ersip_hdr_opttag_list:build/2
          };
header_descr(proxy_require) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_opttag_list:parse/1,
           assemble_fun = fun ersip_hdr_opttag_list:build/2
          };
header_descr(contact) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_contact_list:parse/1,
           assemble_fun = fun ersip_hdr_contact_list:build/2
          };
header_descr(expires) ->
    #descr{required     = optional,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_expires:parse/1,
           assemble_fun = fun ersip_hdr_expires:build/2
          };
header_descr(minexpires) ->
    #descr{required     = optional,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_expires:parse/1,
           assemble_fun = fun ersip_hdr_expires:build/2
          };
header_descr(date) ->
    #descr{required     = optional,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_date:parse/1,
           assemble_fun = fun ersip_hdr_date:build/2
          };
header_descr(www_authenticate) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_auth:parse/1,
           assemble_fun = fun ersip_hdr_auth:build/2
          };
header_descr(authorization) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_auth:parse/1,
           assemble_fun = fun ersip_hdr_auth:build/2
          };
header_descr(proxy_authenticate) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_auth:parse/1,
           assemble_fun = fun ersip_hdr_auth:build/2
          };
header_descr(proxy_authorization) ->
    #descr{required     = optional,
           may_appear   = multiple,
           parse_fun    = fun ersip_hdr_auth:parse/1,
           assemble_fun = fun ersip_hdr_auth:build/2
          };
header_descr(subscription_state) ->
    #descr{required     = optional,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_subscription_state:parse/1,
           assemble_fun = fun ersip_hdr_subscription_state:build/2
          };
header_descr(event) ->
    #descr{required     = {requests, [ersip_method:notify(), ersip_method:subscribe()]},
           may_appear   = once,
           parse_fun    = fun ersip_hdr_event:parse/1,
           assemble_fun = fun ersip_hdr_event:build/2
          };
header_descr(refer_to) ->
    #descr{required     = {requests, [ersip_method:refer()]},
           may_appear   = once,
           parse_fun    = fun ersip_hdr_refer_to:parse/1,
           assemble_fun = fun ersip_hdr_refer_to:build/2
          };
header_descr(replaces) ->
    #descr{required     = optional,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_replaces:parse/1,
           assemble_fun = fun ersip_hdr_replaces:build/2
          };
header_descr(rseq) ->
    #descr{required     = optional,
           may_appear   = once,
           parse_fun    = fun ersip_hdr_rseq:parse/1,
           assemble_fun = fun ersip_hdr_rseq:build/2
          };
header_descr(rack) ->
    #descr{required     = {requests, [ersip_method:prack()]},
           may_appear   = once,
           parse_fun    = fun ersip_hdr_rack:parse/1,
           assemble_fun = fun ersip_hdr_rack:build/2
          }.


