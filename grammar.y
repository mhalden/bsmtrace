%{
/*-
 * Copyright (c) 2007 Aaron L. Meihm
 * Copyright (c) 2007 Christian S.J. Peron
 * All rights reserved.
 *
 * $Id$
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "includes.h"

extern int	yylex(void);

static struct bsm_sequence	*bs_state;	/* BSM sequence state */
static struct bsm_set		*set_state;	/* BSM set state */
static struct bsm_state	*bm_state;	/* BSM state */
static struct array		 array_state;	/* Volatile array */
static struct logchannel	*log_state;
%}

%union {
	u_int32_t		 num;
	char			*str;
	struct array		*array;
	struct bsm_set		*bsm_set;
	struct bsm_state	*bsm_state;
}

%token	DEFINE SET OBJECT SEQUENCE STATE EVENT TRIGGER
%token	STATUS MULTIPLIER OBRACE EBRACE SEMICOLON COMMA SUBJECT
%token	STRING ANY SUCCESS FAILURE INTEGER TIMEOUT NOT HOURS MINUTES DAYS
%token	PRIORITY WEEKS SECONDS NONE QUOTE OPBRACKET EPBRACKET LOGCHAN
%token	DIRECTORY LOG SCOPE SERIAL
%type	<num> status_spec SUCCESS FAILURE INTEGER multiplier_spec timeout_spec
%type	<num> serial_spec negate_spec priority_spec scope_spec
%type	<str> STRING
%type	<array> set_list set_list_ent
%type	<bsm_set> anon_set
%type	<bsm_state> state

%%

root	: /* empty */
	| root cmd
	;

cmd	:
	define_def
	| log_channel
	| sequence_def
	;

define_def:
	DEFINE SET STRING OPBRACKET STRING EPBRACKET
	{
		assert(set_state == NULL);
		if ((set_state = calloc(1, sizeof(*set_state))) == NULL)
			bsmtrace_error(1, "%s: calloc failed", __func__);
		if ((set_state->bss_type = conf_set_type($5)) == -1)
			conf_detail(0, "%s: invalid set type", $5);
		/* free() this later. */
		set_state->bss_name = $3;
	}
	OBRACE set_list SEMICOLON EBRACE SEMICOLON
	{
		struct array *src, *dst;

		src = $9;
		dst = &set_state->bss_data;
		*dst = *src;
		bzero(&array_state, sizeof(struct array));
		TAILQ_INSERT_TAIL(&bsm_set_head, set_state, bss_glue);
		set_state = NULL;
	}
	;

log_channel:
	LOGCHAN STRING OPBRACKET STRING EPBRACKET
	{
		assert(log_state == NULL);
		log_state = calloc(1, sizeof(*log_state));
		if (log_state == NULL)
			bsmtrace_error(1, "%s: calloc failed", __func__);
		log_state->log_type = log_chan_type($4);
		if (log_state->log_type < 0)
			conf_detail(0, "%s: invalid log channel type", $4);
		log_state->log_name = strdup($2);
		log_state->log_handler = log_chan_handler($4);
	}
	OBRACE log_channel_options EBRACE SEMICOLON
	{
		TAILQ_INSERT_HEAD(&log_head, log_state, log_glue);
		log_state = NULL;
	}
	;

syslog_pri_spec:
	PRIORITY STRING SEMICOLON
	{
		assert(log_state != NULL);
		if (log_state->log_type != LOG_CHANNEL_SYSLOG)
			conf_detail(0, "priority may only be used for "
			    "syslog log channels");
		log_state->log_data.syslog_pri = log_syslog_encode($2);
		if (log_state->log_data.syslog_pri < 0)
			conf_detail(0, "%s: invalid syslog priority", $2);
	}
	;

directory_spec:
	DIRECTORY STRING SEMICOLON
	{
		struct stat sb;

		assert(log_state != NULL);
		if (stat($2, &sb) < 0)
			conf_detail(0, "%s: %s", $2, strerror(errno));
		if ((sb.st_mode & S_IFDIR) == 0)
			conf_detail(0, "%s: not a directory", $2);
		if ((sb.st_mode & S_IROTH) != 0)
			bsmtrace_error(0, "%s: world readable", $2);
		log_state->log_data.bsm_log_dir = strdup($2);
		if (log_state->log_data.bsm_log_dir == NULL)
			bsmtrace_error(1, "%s: strdup failed", __func__);
	}
	;

log_channel_options: /* Empty */
	| log_channel_options syslog_pri_spec
	| log_channel_options directory_spec
	;

negate_spec: /* Empty */
	{
		$$ = 0;
	}
	| NOT
	{
		$$ = 1;
	}
	;

anon_set:
	OPBRACKET STRING EPBRACKET OBRACE
	{
		struct bsm_set *new;

		if ((new = calloc(1, sizeof(*new))) == NULL)
			bsmtrace_error(1, "%s: calloc failed", __func__);
		if ((new->bss_type = conf_set_type($2)) == -1)
			conf_detail(0, "%s: invalid set type", $2);
		set_state = new;
	}
	set_list SEMICOLON EBRACE
	{
		struct array *src, *dst;

		assert(set_state->bss_type != 0);
		src = $6;
		dst = &set_state->bss_data;
		*dst = *src;
		bzero(&array_state, sizeof(struct array));
		$$ = set_state;
		set_state = NULL;
	}
	;

subject_spec:
	SUBJECT ANY SEMICOLON
	{
		bs_state->bs_seq_flags |= BSM_SEQUENCE_SUBJ_ANY;
		bs_state->bs_subj_type = SET_TYPE_AUID;
	}
	| SUBJECT negate_spec STRING SEMICOLON
	{
		struct bsm_set *sptr;

		if ((sptr = conf_get_bsm_set($3)) == NULL)
			conf_detail(0, "%s: invalid set", $3);
		conf_sequence_set_subj(bs_state, sptr, $2);
	}
	| SUBJECT negate_spec anon_set SEMICOLON
	{
		assert($3->bss_type != 0);
		conf_sequence_set_subj(bs_state, $3, $2);
	}
	;

timeout_spec:
	TIMEOUT INTEGER SECONDS SEMICOLON
	{
		$$ = $2;
	}
	| TIMEOUT INTEGER HOURS SEMICOLON
	{
		$$ = $2 * 3600;
	}
	| TIMEOUT INTEGER MINUTES SEMICOLON
	{
		$$ = $2 * 60;
	}
	| TIMEOUT INTEGER DAYS SEMICOLON
	{
		$$ = $2 * 3600 * 24;
	}
	| TIMEOUT INTEGER WEEKS SEMICOLON
	{
		$$ = $2 * 3600 * 24 * 7;
	}
	| TIMEOUT NONE SEMICOLON
	{
		$$ = 0;
	}
	;

sequence_def:
	SEQUENCE
	{
		assert(bs_state == NULL);
		if ((bs_state = calloc(1, sizeof(*bs_state))) == NULL)
			bsmtrace_error(1, "%s: calloc failed", __func__);
		/* This will be a parent sequence. */
		bs_state->bs_seq_flags |= BSM_SEQUENCE_PARENT;
		bs_state->bs_seq_scope = BSM_SCOPE_GLOBAL;
                bs_state->bs_subj_type = SET_TYPE_NOOP;
		TAILQ_INIT(&bs_state->bs_mhead);
	}
	STRING OBRACE sequence_options EBRACE SEMICOLON
	{
                /* Check for valid subject specified in sequence options. */
                if (bs_state->bs_subj_type == SET_TYPE_NOOP)
                        conf_detail(0, "%s: must specify a subject", $3);
		if (conf_get_parent_sequence($3) != NULL)
			conf_detail(0, "%s: sequence exists", $3);
		if ((bs_state->bs_label = strdup($3)) == NULL)
			bsmtrace_error(1, "%s: strdup failed", __func__);
		TAILQ_INSERT_HEAD(&s_parent, bs_state, bs_glue);
		bs_state = NULL;
	}
	;

priority_spec:
	PRIORITY INTEGER SEMICOLON
	{
		$$ = $2;
	}
	;

log_spec:
	LOG STRING SEMICOLON
	{
		struct bsm_set *sptr;

		if ((sptr = conf_get_bsm_set($2)) == NULL)
			conf_detail(0, "%s: invalid set", $2);
		if (sptr->bss_type != SET_TYPE_LOGCHANNEL)
			conf_detail(0, "%s: supplied set is not of type "
			    "logchannel", $2);
		assert(bs_state != NULL);
		conf_set_log_channel(sptr, bs_state);
	}
	| LOG anon_set SEMICOLON
	{
		assert(bs_state != NULL);
		if ($2->bss_type != SET_TYPE_LOGCHANNEL)
			conf_detail(0, "supplied set is not of type "
			    "logchannel");
		conf_set_log_channel($2, bs_state);
	}
	;

scope_spec:
	SCOPE STRING SEMICOLON
	{
		int scope;

		scope = conf_return_scope($2);
		if (scope < 0)
			conf_detail(0, "%s: invalid scope", $2);
		bs_state->bs_seq_scope = scope;
	}
	;

serial_spec:
	SERIAL INTEGER SEMICOLON
	{
		$$ = $2;
	}
	;

sequence_options: /* Empty */
	| sequence_options subject_spec
	{
		assert(bs_state != NULL);
	}
	| sequence_options timeout_spec
	{
		assert(bs_state != NULL);
		bs_state->bs_timeout = $2;
	}
	| sequence_options state
	{
		assert(bs_state != NULL);
		conf_handle_multiplier(bs_state, $2);
	}
	| sequence_options priority_spec
	{
		assert(bs_state != NULL);
		bs_state->bs_priority = $2;
	}
	| sequence_options log_spec
	| sequence_options scope_spec
	{
		assert(bs_state != NULL);
		bs_state->bs_seq_flags |= $2;
	}
	| sequence_options serial_spec
	{
		bs_state->bs_seq_serial = $2;
	}
	;

type_spec:
	EVENT negate_spec STRING SEMICOLON
	{
		struct array *src, *dst;
		struct bsm_set *ptr;

		if ((ptr = conf_get_bsm_set($3)) == NULL)
			conf_detail(0, "%s: invalid set", $3);
		if (ptr->bss_type != SET_TYPE_AUCLASS &&
		    ptr->bss_type != SET_TYPE_AUEVENT)
			conf_detail(0, "supplied set contains no audit "
			    "events or classes");
		bm_state->bm_event_type = ptr->bss_type;
		src = &ptr->bss_data;
		dst = &bm_state->bm_auditevent;
		*dst = *src;
		bzero(&array_state, sizeof(struct array));
		dst->a_negated = $2;
	}
	| EVENT negate_spec anon_set SEMICOLON
	{
		struct array *src, *dst;

		if ($3->bss_type != SET_TYPE_AUCLASS &&
		    $3->bss_type != SET_TYPE_AUEVENT)
			conf_detail(0, "supplied set contains no audit "
			    "events or classes");
		bm_state->bm_event_type = $3->bss_type;
		src = &$3->bss_data;
		dst = &bm_state->bm_auditevent;
		*dst = *src;
		bzero(&array_state, sizeof(struct array));
		dst->a_negated = $2;
	}
	;

object_spec:
	OBJECT negate_spec STRING SEMICOLON
	{
		struct array *src, *dst;
		struct bsm_set *ptr;

		if ((ptr = conf_get_bsm_set($3)) == NULL)
			conf_detail(0, "%s: invalid set", $3);
#ifdef PCRE
		if (ptr->bss_type != SET_TYPE_PATH &&
		    ptr->bss_type != SET_TYPE_PCRE)
			conf_detail(0, "objects must be of type path or pcre");
#else
		if (ptr->bss_type != SET_TYPE_PATH)
			conf_detail(0, "objects must be of type path");
#endif
		src = &ptr->bss_data;
		dst = &bm_state->bm_objects;
		*dst = *src;
		bzero(&array_state, sizeof(struct array));
		dst->a_negated = $2;
	}
	| OBJECT negate_spec anon_set SEMICOLON
	{
		struct array *src, *dst;

		src = &$3->bss_data;
#ifdef PCRE
		if ($3->bss_type != SET_TYPE_PATH &&
		    $3->bss_type != SET_TYPE_PCRE)
			conf_detail(0, "objects must be of type path or pcre");
#else
		if ($3->bss_type != SET_TYPE_PATH)
			conf_detail(0, "objects must be of type path");
#endif
		dst = &bm_state->bm_objects;
		*dst = *src;
		bzero(&array_state, sizeof(struct array));
		dst->a_negated = $2;
	}
	;

status_spec:
	STATUS SUCCESS SEMICOLON
	{
		$$ = EVENT_SUCCESS;
	}
	| STATUS FAILURE SEMICOLON
	{
		$$ = EVENT_FAILURE;
	}
	| STATUS ANY SEMICOLON
	{
		$$ = EVENT_SUCCESS_OR_FAILURE;
	}
	;

multiplier_spec:
	MULTIPLIER INTEGER SEMICOLON
	{
		$$ = $2;
	}
	;

trigger_spec:
	TRIGGER STRING SEMICOLON
	{
		strlcpy(bm_state->bm_trig, $2, sizeof(bm_state->bm_trig));
	}
	;

state_options: /* empty */
	| state_options type_spec
	| state_options status_spec
	{
		assert(bm_state != NULL);
		bm_state->bm_status = $2;
	}
	| state_options multiplier_spec
	{
		assert(bm_state != NULL);
		bm_state->bm_multiplier = $2;
	}
	| state_options object_spec
	| state_options trigger_spec
	;

state:
	STATE
	{
		assert(bm_state == NULL);
		if ((bm_state = calloc(1, sizeof(*bm_state))) == NULL)
			bsmtrace_error(1, "%s: calloc failed", __func__);
	}
	OBRACE state_options EBRACE SEMICOLON
	{
		$$ = bm_state;
		bm_state = NULL;
	}
	;

set_list:
	set_list_ent
	{
		$$ = &array_state;
	}
	| set_list COMMA set_list_ent
	{
		assert($1 != NULL && $3 != NULL);
		$$ = &array_state;
	}
	;

set_list_ent:
	STRING
	{
		assert(set_state != NULL && $1 != NULL);
		conf_array_add($1, &array_state, set_state->bss_type);
		free($1);
		$$ = &array_state;
	}
	| INTEGER
	{
		int val, len;
		char *str;

		len = 1;
		val = $1;
		while (val > 9) {
			++len;
			val /= 10;
		}
		str = calloc(1, len + 1);
		if (str == NULL)
			bsmtrace_error(1, "%s: calloc failed", __func__);
		str += len;
		do {
			*--str = '0' + ($1 % 10);
			$1 /= 10;
		} while ($1);
		conf_array_add(str, &array_state, set_state->bss_type);
		$$ = &array_state;
	}
	| OPBRACKET STRING EPBRACKET
	{
		assert($2 != NULL);
		conf_array_add($2, &array_state, set_state->bss_type);
		$$ = &array_state;
	}
	;
