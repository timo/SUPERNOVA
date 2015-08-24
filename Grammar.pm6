# Grammar.pm6 --- Pod6 Grammar

use v6;

# since this will eventually be plugged into the rakudo grammar/actions setup,
# we need to be as NQP-y as can be reasonably done. Why not just write it in NQP
# then? Because we wouldn't have access to $*W or the other hooks into Perl6 we
# could have, so better to work in a system with those things than to try vainly
# to work around it while out of core.

use nqp;

# these shims are to explicitly mark stuff that wouldn't be doing this in NQP-land
sub shim-unbox_i(Int $a) { nqp::unbox_i($a) }
sub shim-unbox_s(Str $a) { nqp::unbox_s($a) }

sub shim-box_i(int $a) { nqp::box_i($a, Int) }

#use Grammar::Tracer;

use Exception;

role GramError {
    has $!nl-list;

    # like HLL::Compiler.lineof, but gives a column too
    method linecol($text, $at) {
        my $tsize := nqp::chars($text);
        my $lookfrom := 0;
        my $line := 0;

        my $pos := nqp::list_i();

        unless $!nl-list {
            $!nl-list := nqp::list_i();

            my sub nextnl {
                nqp::findcclass(nqp::const::CCLASS_NEWLINE, $text, $lookfrom, $tsize);
            }

            while nqp::islt_i(($lookfrom := nextnl()), $tsize) {
                # don't count \r\n as two newlines
                if nqp::eqat($text, "\r\n", $lookfrom) {
                    $lookfrom := nqp::add_i($lookfrom, 2);
                } else {
                    $lookfrom := nqp::add_i($lookfrom, 1);
                }

                # unlike HLL::Compiler's lineof, we count \r\n as ending after
                # the \n. This opens up the chance that we'll get a pointer in
                # the middle (\r⏏\n) identifying itself on the line \r\n ends
                # (whereas lineof would report for the next line), but it's
                # generally not a good idea to wind up there anyway ☺
                nqp::push_i($!nl-list, $lookfrom);
            }
        }

        # now to find the right line number

        my $lo := 0;
        my $hi := nqp::elems($!nl-list);
        my $linefind;

        while nqp::islt_i($lo, $hi) {
            $linefind := nqp::div_i(nqp::add_i($lo, $hi), 2);
            if nqp::isgt_i(nqp::atpos_i($!nl-list, $linefind), $at) {
                $hi := $linefind;
            } else {
                $lo := nqp::add_i($linefind, 1);
            }
        }

        nqp::bindpos_i($pos, 0, nqp::add_i($lo, 1));

        # now to get the column
        if $lo == 0 {
            nqp::bindpos_i($pos, 1, $at);
        } else {
            nqp::bindpos_i($pos, 1, nqp::sub_i($at, nqp::atpos_i($!nl-list, nqp::sub_i($lo, 1))));
        }

        $pos;
    }

    method takeline(str $fromthis, int $lineno) {
        my $arrline := nqp::sub_i($lineno, 1);

        my $startpos;
        my $endpos;
        if $arrline == 0 {
            $startpos := 0;
        } else {
            $startpos := nqp::atpos_i($!nl-list, nqp::sub_i($arrline, 1));
        }

        if $arrline == nqp::elems($!nl-list) {
            $endpos := nqp::chars($fromthis);
        } else {
            $endpos := nqp::atpos_i($!nl-list, $arrline);
        }

        nqp::substr($fromthis, $startpos, nqp::sub_i($endpos, $startpos));
    }

    # XXX Use ANSIColor
    # simple parse failure
    method parse-fail($msg = "No message was given") {
        $/ = self.MATCH();

        my $string := shim-unbox_s($/.orig);

        my $failat := self.linecol($string, shim-unbox_i($/.from));

        my $fline := nqp::atpos_i($failat, 0);
        my $fcol  := nqp::atpos_i($failat, 1);

        my $errorline := nqp::atpos(nqp::split("\n", $string), $fline - 1);
        note "\e[41;1m===SORRY!===\e[0m Error in parsing file:";
        note $msg;
        note "In file at line ", $fline, ", col ", $fcol, ":";
        note "\e[32m", nqp::substr($errorline, 0, $fcol),
             "\e[33m⏏",
             "\e[31m", nqp::substr($errorline, $fcol),
             "\e[0m";

        exit(1);
    }

    method make-ex($/, Exception $type, %opts is copy) {
        my $linecol := self.linecol(shim-unbox_s($/.orig), shim-unbox_i($/.from));

        my $fled-line := self.takeline(shim-unbox_s($/.orig), nqp::atpos_i($linecol, 0));

        %opts<goodpart> := nqp::substr($fled-line, 0, nqp::atpos_i($linecol, 1));
        %opts<badpart>  := nqp::substr($fled-line, nqp::atpos_i($linecol, 1));

        %opts<err-flc> := X::FLC.new(file => $*FILENAME,
                                         line => shim-box_i(nqp::atpos_i($linecol, 0)),
                                         col  => shim-box_i(nqp::atpos_i($linecol, 1)));

        if %opts<HINT-MATCH>:exists {
            my $hint := %opts<HINT-MATCH>;

            my $hintlc := self.linecol(shim-unbox_s($hint.orig), shim-unbox_i($hint.from));

            my $hint-line := self.takeline(shim-unbox_s($hint.orig), nqp::atpos_i($hintlc, 0));

            %opts<hint-beforepoint> := nqp::substr($hint-line, 0, nqp::atpos_i($hintlc, 1));
            %opts<hint-afterpoint>  := nqp::substr($hint-line, nqp::atpos_i($hintlc, 1));

            %opts<hint-flc> := X::FLC.new(file => $*FILENAME,
                                              line => shim-box_i(nqp::atpos_i($hintlc, 0)),
                                              col  => shim-box_i(nqp::atpos_i($hintlc, 1)));

            %opts<HINT-MATCH>:delete;
        }

        $type.new(|%opts);
    }

    # stuff that's potentially troublesome, but doesn't prevent a useful result
    # from the parser
    method worry(Exception $type, *%exnameds) {
        @*WORRIES.push(self.make-ex(self.MATCH, $type, %exnameds));
        self;
    }

    # stuff that leaves the parser unable to return something useful, but
    # doesn't prevent the parser from continuing (in order to find more
    # sorrows/panics)
    method sorry(Exception $type, *%exnameds) {
        @*SORROWS.push(self.make-ex(self.MATCH, $type, %exnameds));

        if +@*SORROWS >= $*SORRY_LIMIT { # we've got too much to be sorry for, bail
            self.give-up-ghost();
        }
        self;
    }

    # curse of fatal death --- there's no way the parser can even parse more
    # stuff after something like this
    method panic(Exception $type, *%exnameds) {
        my $ex := self.make-ex(self.MATCH, $type, %exnameds);
        if +@*SORROWS || +@*WORRIES {
            self.give-up-ghost($ex);
        } else {
            $ex.throw;
        }
        self;
    }

    method cry-sorrows() {
        if +@*SORROWS == 1 && !+@*WORRIES {
            @*SORROWS[0].throw;
        } elsif @*SORROWS > 0 {
            self.give-up-ghost();
        }
        self;
    }

    method express-worries() {
        return self unless +@*WORRIES;
        if +@*SORROWS {
            warn "Issue in Grammar Error Reporter: worries being expressed before sorrows cried";
        }

        self.give-up-ghost();
        self;
    }

    method give-up-ghost(X::Pod6 $panic?) {
        my $ghost;
        with $panic {
            $ghost = X::Epitaph.new(:$panic, worries => @*WORRIES, sorrows => @*SORROWS);
        } else {
            $ghost = X::Epitaph.new(worries => @*WORRIES, sorrows => @*SORROWS);
        }

        if +@*SORROWS {
            $ghost.throw
        } else {
            print($ghost.gist)
        }
    }
}

# TO-CORE nqp-ify class
class PodScope {
    has $!fc-need-allow = False;
    has @!fc-allowed;
    has $!fc-blankstop = True;
    has $!vmargin = 0;
    has $!implied-para = False;
    has $!implied-code = False;

    has $!locked-scope = False; # for things like =config, to avoid other rules changing stuff

    has %!config;

    has $!implied-para-mode = False;
    has $!implied-code-mode = True;
    has $!imp-code-vmargin = 0;

    method enter-para { $!implied-code-mode || !$!implied-para ?? False !! ($!implied-para-mode = True) }
    method exit-para  { $!implied-para-mode = False }
    method enter-code { $!implied-para-mode || !$!implied-code ?? False !! ($!implied-code-mode = True) }
    method exit-code  { $!implied-code-mode = False }

    method set-this-config(Str $key, Str $value) {
        # make sure the key used here isn't a valid P6 identifier, to avoid any
        # conflicts with block names
        %!config<-THIS->{$key} = $value;
    }

    method set-config-for(Str $block, Str $key, Str $value) {
        %!config{$block}{$key} = $value;
    }

    method get-this-config(Str $key) { %!config<-THIS->{$key} }
    method get-config-for(Str $block, Str $key) { %!config{$block}{$key} }

    method lock-scope   { $!locked-scope = True  }
    method unlock-scope { $!locked-scope = False }

    method blanks-stop-fc($a) { unless $!locked-scope { $!fc-blankstop = ?$a } }
    method fc-stop-at-blank   { $!fc-blankstop }

    method disable-fc { unless $!locked-scope { $!fc-need-allow = True } }
    method allow-fc($fc) {
        unless $!locked-scope {
            die "wrong fc $fc" unless $fc ~~ "A".."Z";
            @!fc-allowed.push($fc)
        }
    }
    method can-fc($fc) {
        if $!fc-need-allow || $!implied-code-mode {
            $fc ~~ @!fc-allowed;
        } else {
            $fc ~~ "A".."Z"
        }
    }

    method imply-para { unless $!locked-scope { $!implied-para = True } }
    method imply-code { unless $!locked-scope { $!implied-code = True } }
    method unimply-para { unless $!locked-scope { $!implied-para = False } }
    method unimply-code { unless $!locked-scope { $!implied-code = False } }
    method can-para { $!implied-para }
    method can-code { $!implied-code }

    multi method set-margin(Int $wsnum, :$code) {
        unless $!locked-scope {
            if $code {
                $!imp-code-vmargin = $wsnum;
            } else {
                $!vmargin = $wsnum;
            }
        }
    }
    multi method set-margin(Str $char, :$code) {
        unless $!locked-scope {
            if $code {
                $!imp-code-vmargin = $char.substr(0, 1);
            } else {
                $!vmargin = $char.substr(0, 1);
            }
        }
    }
    method margin-is-char(:$code) { $code ?? $!imp-code-vmargin ~~ Str !! $!vmargin ~~ Str }
    method margin-is-size(:$code) { $code ?? $!imp-code-vmargin ~~ Int !! $!vmargin ~~ Int }
    method get-margin(:$code) { $code ?? $!imp-code-vmargin !! $!vmargin }
}

grammar Pod6::Grammar does GramError {
    token TOP {
        :my @*POD_SCOPES := nqp::list();

        # TO-CORE stuff we won't need
        :my @*WORRIES;
        :my @*SORROWS;
        :my $*SORRY_LIMIT := 10;

        <.blank_line>*
        [<block>
         <.blank_line>*]+

        [ $ || <.panic(X::Pod6::Didn'tComplete)> ]

        <.cry-sorrows>
        <.express-worries>
    }

    # XXX if this grammar is not kept independent in the move to core, this rule
    # has to be renamed
    token ws {
        <!ww> \h*
    }

    # various line handlers, usually called in <.rule> form

    # XXX apparently we're supposed to emulate tab stops in doing this. Gr.
    sub numify-margin($margin) {
        my $de-tabbed := nqp::split("\t", shim-unbox_s($margin));

        if nqp::elems($de-tabbed) == 1 {
            nqp::chars($margin);
        } else {
            nqp::chars(
                nqp::join(
                    nqp::x(
                        " ",
                        ($?TABSTOP // 8)),
                    $de-tabbed));
        }
    }

    method prime_line($margin) {
        my $size = numify-margin($margin);
        @*POD_SCOPES[*-1].set-margin($size);
        self;
    }

    method prime_code_line($margin) {
        my $size = numify-margin($margin);
        @*POD_SCOPES[*-1].set-margin($size, :code);
        self;
    }

    token start_line {
        ^^ " " ** { @*POD_SCOPES[*-1].get-margin() }
    }

    token up_to_code { # for handling the extra indentation on implied code lines
        ^^ " " ** { @*POD_SCOPES[*-1].get-margin(:code) }
    }

    token end_line {
        $$ [\n || $ || <.parse-fail("Unknown line ending found.")>]
    }

    token blank_line {
        ^^ \h* <.end_line>
    }

    token blank_or_eof {
        <.blank_line> || $
    }

    # @*POD_SCOPES handlers

    method enter_scope {
        nqp::push(@*POD_SCOPES, PodScope.new);
        self;
    }

    method exit_scope {
        nqp::pop(@*POD_SCOPES);
        self;
    }

    method lock_scope {
        @*POD_SCOPES[*-1].lock-scope();
        self;
    }

    method unlock_scope {
        @*POD_SCOPES[*-1].unlock-scope();
        self;
    }

    method enter_para {
        @*POD_SCOPES[*-1].enter-para();
        self;
    }

    method enter_code {
        @*POD_SCOPES[*-1].enter-code();
        self;
    }

    method exit_para {
        @*POD_SCOPES[*-1].exit-para();
        self;
    }

    method exit_code {
        @*POD_SCOPES[*-1].exit-code();
        self;
    }

    # high-level block handling

    token block {
        ^^ $<litmargin>=(\h*) <?before <new_directive>>
        <.enter_scope>
        {self.prime_line(~$<litmargin>)}

        <directive>
        <.exit_scope>
    }

    proto token directive {*}

    multi token directive:sym<delim> {
        "=begin" <.ws> # XXX want :: here
            <block_name> <.ws>
            <configset> <.end_line>

        <extra_config_line>*

        {@*POD_SCOPES[*-1].blanks-stop-fc(0)}

        [ <!before \h* "=end">
          [
          | <block>
          | <.start_line> <pseudopara>
          | <.blank_line>
          ]
        ]*

        <.start_line> "=end" <.ws> [$<block_name>
                                   || <badname=.block_name> {$<badname>.CURSOR.panic(X::Pod6::MismatchedEnd, HINT-MATCH => $/)}
                                   ] <.ws> <.end_line>
    }

    multi token directive:sym<para> {
        "=for" <.ws> # XXX want :: here
            <block_name> <.ws>
            <configset> <.end_line>

        <extra_config_line>*

        {@*POD_SCOPES[*-1].blanks-stop-fc(1)}

        <.start_line> <pseudopara>

        <.blank_or_eof>
    }

    multi token directive:sym<abbr> {
        \= <!not_name> <block_name> <.ws>

        {@*POD_SCOPES[*-1].blanks-stop-fc(1)}

        # implied code blocks can only start on the next line, since only there
        # can we check for indentation. However, since we eat up all the
        # whitespace on the first line (see above <.ws>), we don't need to do
        # anything special.

        [<.end_line> <.start_line>]? <pseudopara>

        <.blank_or_eof>
    }

    multi token directive:sym<encoding> {
        "=encoding" <.ws> # ::
        $<encoding>=[\N+ <.end_line>
            [<!blank_or_eof> <.start_line> \N+ <.end_line>]*]

        <.blank_or_eof>

        {$¢.worry(X::Pod6::Encoding, target-enc => ~$<encoding>)}
    }

    multi token directive:sym<alias> {
        "=alias" <.ws> $<AVal>=[<.ident> +% \-] <.ws>
        [<.end_line> {$¢.panic(X::Pod6::Alias, atype => "Contextual")}]?

        \N+ {$¢.sorry(X::Pod6::Alias, atype => "Macro")}
        <.end_line> <.blank_or_eof>
    }

    multi token directive:sym<config> {
        "=config" <.ws> #`(::) <.lock_scope>
        $<thing>=[<.block_name>|<[A..Z]> "<>"] <.ws>
        <configset> <.end_line>
        <extra_config_line>*
        <.unlock_scope>
    }

    token block_name {
        || [<standard_name> | <semantic_standard_name>]
        || <not_name> { $¢.panic(X::Pod6::Block::DirectiveAsName, culprit => ~$<not_name>) }
        || <reserved_name> { $¢.sorry(X::Pod6::Block::ReservedName, culprit => ~$<reserved_name>) }
        || <typename>
    }

    token standard_name {
        | code                                       { @*POD_SCOPES[*-1].imply-code() } { @*POD_SCOPES[*-1].disable-fc() }
        | comment
        | data
        | defn    { @*POD_SCOPES[*-1].imply-para() }
        | finish  { @*POD_SCOPES[*-1].imply-para() }
        | head
        | input
        | item    { @*POD_SCOPES[*-1].imply-para() } { @*POD_SCOPES[*-1].imply-code() }
        | nested  { @*POD_SCOPES[*-1].imply-para() } { @*POD_SCOPES[*-1].imply-code() }
        | output
        | para
        | pod     { @*POD_SCOPES[*-1].imply-para() } { @*POD_SCOPES[*-1].imply-code() }
        | table
    }

    # since S26 states that each name and its plural is reserved, I decided to
    # pluralize even those that don't have a grammatical plural :P
    token semantic_standard_name {
        [
        | NAMES?
        | AUTHORS?
        | VERSIONS?
        | CREATEDS?
        | EMULATES[ES]?
        | EXCLUDES[ES]?
        | SYNOPS<[IE]>S
        | DESCRIPTIONS?
        | USAGES?
        | INTERFACES?
        | METHODS?
        | SUBROUTINES?
        | OPTIONS?
        | DIAGNOSTICS?
        | ERRORS?
        | WARNINGS?
        | DEPENDENC[Y|IES]
        | BUGS?
        | SEE\-ALSOS?
        | ACKNOWLEDGMENTS?
        | COPYRIGHTS?
        | DISCLAIMERS?
        | LICENCES?
        | LICENSES?
        | TITLES?
        | SECTIONS?
        | CHAPTERS?
        | APPENDI[X|CES]
        | TOCS?
        | IND[EX|ICES]
        | FOREWORDS?
        | SUMMAR[Y|IES]
        ] { @*POD_SCOPES[*-1].imply-para(); @*POD_SCOPES[*-1].imply-code() }
    }

    token not_name {
        | begin
        | for
        | end
        | config
        | alias
        | encoding
    }

    token reserved_name { [<:Lower>+ | <:Upper>+] <!ww> }

    token typename {
        | <:Upper>+ <:Lower> [<:Upper>|<:Lower>]*
        | <:Lower>+ <:Upper> [<:Lower>|<:Upper>]*
    }

    # unfortunately, even after transferring to CORE, we'll need our own rule to
    # handle config options, because we can only accept constant keys and
    # values, but Perl6::Grammar's parser allow non-constants
    token configopt {
        :my $*ADV_BINARY := -1;
        [
        | \: [\! {$*ADV_BINARY := 0}]?
          [$<ckey>=[<.ident> +% \-] || <.non-const-term>]
          $<cvalue>=[
            | [
              | <podassociative>
              | <podpositional>
              | \< ~ \> $<podqw>=[ [[<!before \h | <?[>]>> .]+] +%% <.ws> ]
              | \( ~ \) [[<podstr>|<podint>]||<.non-const-term>]
              ] [ <?{$*ADV_BINARY == 0}> {$¢.panic(X::Pod6::BadConfig, message => "Cannot negate adverb and provide value ~$<cvalue>")} ]
            | {unless $*ADV_BINARY == 0 { $*ADV_BINARY := 1} }
              [ <!before \s> $<badtext>=[[\S & <-[,]>]+] {$<badtext>.CURSOR.panic(X::Pod6::BadConfig, message => "Unknown text \"$0\" after key")} ]?
          ]
        | [$<ckey>=[<.ident> +% \-] || <.non-const-term>]
          <.ws> ["=>" || {$¢.panic(X::Pod6::BadConfig, message => "Bad key; expecting => after key or : before it")}]
          <.ws>
          $<cvalue>=[
              [
              | <podint>
              | <podstr>
              | <podpositional>
              | <podassociative>
              ] || <.non-const-term>
                || {$¢.panic(X::Pod6::BadConfig, message => "No value found after fatarrow; please use :$<ckey> if you meant to set a binary flag")}
          ]
        ]
    }

    # TO-CORE: podint will likely want to parse any <integer>, and podstr any
    # kind of Q lang (though variable interpolation is disallowed)
    token podint { \d+ }
    token podstr {
        | \' ~ \' [<-['\\]> | \\\\ | \\\']+
        | \" ~ \" [<-["\\]> | \\\\ | \\\"]+
    }

    token podpositional {
        \[ ~ \] [[[<podint>|<podstr>]||<.non-const-term>] +% [<.ws> \, <.ws>]]
    }

    token podassociative {
        \{ ~ \} [<configopt> +% [<.ws> \, <.ws>]]
    }

    # this token lives to produce an error. Do not call unless/until you know
    # it's needed
    token non-const-term {
        | <?before <+[$@%&]> | "::"> (\S\S?! <.ident>) {$¢.panic(X::Pod6::BadConfig, message => "Variable \"$0\" found in pod configuration; only constants are allowed")}
        | "#" <.panic(X::Pod6::BadConfig, message => "Unexpected # in pod configuration. (Were you trying to comment out something?)")>
        | ([\S & <-[\])>]>]+) {$¢.panic(X::Pod6::BadConfig, message => "Unknown term \"$0\" in configuration. Only constants are allowed.")}
    }

    token configset {
        <configopt> +%% [<.ws> [$<badcomma>=[\,] <.ws> {$<badcomma>[*-1].CURSOR.worry(X::Pod6::BadConfig::Comma)}]?]
    }

    token extra_config_line {
        <.start_line> \= \h+
        <configset>
        <.end_line>
    }


    proto token pseudopara {*}
    multi token pseudopara:sym<implicit_code> {
        <?{@*POD_SCOPES[*-1].can-code()}> (\h+) # probably want ::

        <.enter_code>
        {self.prime_code_line(~$0)}

        <!before <new_directive>> $<line>=(<one_token_text>+ <.end_line>)
        [<!blank_or_eof> <.start_line> <.up_to_code> <!before <new_directive>> $<line>=(<one_token_text>+ <.end_line>)]*

        <.exit_code>
    }

    multi token pseudopara:sym<implicit_para> {
        <?{@*POD_SCOPES[*-1].can-para()}> # probably want ::

        # we can accept indented stuff, _if_ code blocks can't be implicit here
        [<!{@*POD_SCOPES[*-1].can-code()}> \h*]?

        <.enter_para>

        <!before <new_directive>> <one_token_text>+ <.end_line>
        [<!blank_or_eof> <.start_line> <!before <new_directive>> <one_token_text>+ <.end_line>]*

        <.exit_para>
    }

    multi token pseudopara:sym<nothing_implied> {
        <!{@*POD_SCOPES[*-1].can-code() || @*POD_SCOPES[*-1].can-para()}> # probably not needed when :: used on the other multis
        <!before <new_directive>> <one_token_text>+ <.end_line>
        [<!blank_or_eof> <.start_line> <!before <new_directive>> <one_token_text>+ <.end_line>]*
    }

    token one_token_text {
        \N | <format_code>
    }

    token format_code {
        :my $endcond;
        :my $opener;
        :my $closeleft := shim-unbox_i(1);
        $<which>=[ <[A..Z]> ] <?{@*POD_SCOPES[*-1].allow-fc(~$<which>)}>
        [
        | $<restart>=(\<+) {$opener := "<"; $endcond := ">" x (~$<restart>).chars}
        | $<restart>=(\«+) {$opener := "«"; $endcond := "»" x (~$<restart>).chars}
        ]

        [ <?{$closeleft > 0}>
          [
          | $<restart>
            [
            | $opener+ { $¢.panic(X::Pod6::FCode::TooManyAngles) }
            | { $closeleft := nqp::add_i($closeleft, 1) }
            ]
          | <format_code>
          | $endcond { $closeleft := nqp::sub_i($closeleft, 1) }
          | <.end_line>
            [
            | [ <.new_directive> | <?{@*POD_SCOPES[*-1].fc-stop-at-blank()}> <?blank_line> ]
              <.worry(X::Pod6::FCode::ForcedStop)>
              {$closeleft := 0}
            | <.start_line> .
            ]
          | <!before $endcond> \N
          ]
        ]+
    }

    # meant as a lookahead for when we need to know if a new block would be starting at the current position
    token new_directive {
        \h* \= [
                 [
                   [begin|for|end] \h+
                 ]?
                 [<reserved_name> | <typename>]
               ]
    }
}

# TEMP TEST

my $*FILENAME = "<internal-test>";

my $testpod = q:to/NOTPOD/;
    =begin pod :!autotoc
    =       :autotoc :imconfused :!ok

    =config L<> :okthen

    Hello there L<ALL OK >
    Everybody

    Another para

        AND SOME CODE C««
            GLORIOUS»» CODE
        HELLO SAILOR

    =encoding iso8859-1

    V<>=alias FOOBAR quuxy

    And one more para
        Hanging indent!!~~

    =end pod

    =encoding aosdf aoish ao
    sdifao sodk
NOTPOD

Pod6::Grammar.parse($testpod);

for @<block> {
    say ~$_
}

# get configs workings

# have "implied para" and "implied code" modes on PodScope, to avoid creating extra scopes

# end on blank line, eof, or new block
