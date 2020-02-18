package Promise::ES6;

#----------------------------------------------------------------------
# This module iS NOT a defined interface. Nothing to see here …
#----------------------------------------------------------------------

use strict;
use warnings;

use constant {

    # These aren’t actually defined.
    _RESOLUTION_CLASS => 'Promise::ES6::_RESOLUTION',
    _REJECTION_CLASS  => 'Promise::ES6::_REJECTION',
    _PENDING_CLASS    => 'Promise::ES6::_PENDING',
};

use constant {
    _PID_IDX         => 0,
    _CHILDREN_IDX    => 1,
    _VALUE_SR_IDX    => 2,
    _DETECT_LEAK_IDX => 3,
    _ON_RESOLVE_IDX  => 4,
    _ON_REJECT_IDX   => 5,
    _IS_FINALLY_IDX  => 6,
};

# "$value_sr" => $value_sr
our %_UNHANDLED_REJECTIONS;

sub new {
    my ( $class, $cr ) = @_;

    die 'Need callback!' if !$cr;

    my $value;
    my $value_sr = bless \$value, _PENDING_CLASS();

    my @children;

    my $self = bless [
        $$,
        \@children,
        $value_sr,
        $Promise::ES6::DETECT_MEMORY_LEAKS,
    ], $class;

    # NB: These MUST NOT refer to $self, or else we can get memory leaks
    # depending on how $resolver and $rejector are used.
    my $resolver = sub {
        $$value_sr = $_[0];
        bless $value_sr, _RESOLUTION_CLASS();

        # NB: UNIVERSAL::isa() is used in order to avoid an eval {}.
        # It is acknowledged that many Perl experts strongly discourage
        # use of this technique.
        if ( UNIVERSAL::isa( $$value_sr, __PACKAGE__ ) ) {
            _repromise( $value_sr, \@children, $value_sr );
        }
        elsif (@children) {
            $_->_settle($value_sr) for splice @children;
        }
    };

    my $rejecter = sub {
        $$value_sr = $_[0];
        bless $value_sr, _REJECTION_CLASS();

        $_UNHANDLED_REJECTIONS{$value_sr} = $value_sr;

        # We do not repromise rejections. Whatever is in $$value_sr
        # is literally what rejection callbacks receive.
        if (@children) {
            $_->_settle($value_sr) for splice @children;
        }
    };

    local $@;
    if ( !eval { $cr->( $resolver, $rejecter ); 1 } ) {
        $$value_sr = $@;
        bless $value_sr, _REJECTION_CLASS();

        $_UNHANDLED_REJECTIONS{$value_sr} = $value_sr;
    }

    return $self;
}

sub then {
    my ( $self, $on_resolve, $on_reject ) = @_;

    my $value_sr = bless( \do { my $v }, _PENDING_CLASS() );

    my $new = bless [
        $$,
        [],
        $value_sr,
        $Promise::ES6::DETECT_MEMORY_LEAKS,
        $on_resolve,
        $on_reject,
      ],
      ref($self);

    if ( _PENDING_CLASS eq ref $self->[_VALUE_SR_IDX] ) {
        push @{ $self->[_CHILDREN_IDX] }, $new;
    }
    else {

        # $self might already be settled, in which case we immediately
        # settle the $new promise as well.

        $new->_settle( $self->[_VALUE_SR_IDX] );
    }

    return $new;
}

sub finally {
    my ( $self, $on_finish ) = @_;

    my $value_sr = bless( \do { my $v }, _PENDING_CLASS() );

    my $new = bless(
        [
            $$,
            [],
            $value_sr,
            $Promise::ES6::DETECT_MEMORY_LEAKS,
            $on_finish,
            undef,
            1,  # is finally
        ],
        ref($self),
    );

    if ( _PENDING_CLASS eq ref $self->[_VALUE_SR_IDX] ) {
        push @{ $self->[_CHILDREN_IDX] }, $new;
    }
    else {

        # $self might already be settled, in which case we immediately
        # settle the $new promise as well.

        $new->_settle( $self->[_VALUE_SR_IDX] );
    }

    return $new;
}

sub _repromise {
    my ( $value_sr, $children_ar, $repromise_value_sr ) = @_;
    $$repromise_value_sr->then(
        sub {
            $$value_sr = $_[0];
            bless $value_sr, _RESOLUTION_CLASS;
            $_->_settle($value_sr) for splice @$children_ar;
        },
        sub {
            $$value_sr = $_[0];
            bless $value_sr, _REJECTION_CLASS;
            $_->_settle($value_sr) for splice @$children_ar;
        },
    );
    return;

}

# It’s gainfully faster to inline this:
#sub _is_completed {
#    return (_PENDING_CLASS ne ref $_[0][ _VALUE_SR_IDX ]);
#}

my ($settle_is_rejection, $self_is_finally);

# This method *only* runs to “settle” a promise.
sub _settle {
    my ( $self, $final_value_sr ) = @_;

    die "$self already settled!" if _PENDING_CLASS ne ref $self->[_VALUE_SR_IDX];

    $self_is_finally = $self->[_IS_FINALLY_IDX];

    $settle_is_rejection = _REJECTION_CLASS eq ref $final_value_sr;

    delete $_UNHANDLED_REJECTIONS{$final_value_sr} if $settle_is_rejection;

    # A promise that new() created won’t have on-settle callbacks,
    # but a promise that came from then/catch/finally will.
    # It’s a good idea to delete the callbacks in order to trigger garbage
    # collection as soon and as reliably as possible. It’s safe to do so
    # because _settle() is only called once.
    my $callback = $self->[ ($settle_is_rejection && !$self_is_finally) ? _ON_REJECT_IDX : _ON_RESOLVE_IDX ];

    @{$self}[ _ON_RESOLVE_IDX, _ON_REJECT_IDX ] = ();

    my $value_sr_contents_is_promise = 1;

    if ($callback) {

        # This is the block that runs for promises that were created by a
        # call to then() that assigned a handler for the state that
        # $final_value_sr indicates (i.e., resolved or rejected).

        my ($new_value);

        local $@;

        if ( eval { $self_is_finally ? $callback->() : ($new_value = $callback->($$final_value_sr)); 1 } ) {

            # The callback succeeded. If $new_value is not itself a promise,
            # then $self is now resolved. (Yay!) Note that this is true
            # even if $final_value_sr indicates a rejection: in this case, we’ve
            # just run a successful “catch” block, so resolution is correct.

            # If $new_value IS a promise, though, then we have to wait.
            if ( !UNIVERSAL::isa( $new_value, __PACKAGE__ ) ) {
                $value_sr_contents_is_promise = 0;

                if ($self_is_finally) {

                    # finally() is a bit weird. Assuming its callback succeeds,
                    # it takes its parent’s resolution state. It’s important
                    # that we make a *new* reference to the resolution value,
                    # though, rather than merely using $final_value_sr itself,
                    # because we need $self to have its own entry in
                    # %_UNHANDLED_REJECTIONS.
                    ${ $self->[_VALUE_SR_IDX] } = $$final_value_sr;
                    bless $self->[_VALUE_SR_IDX], ref $final_value_sr;

                    $_UNHANDLED_REJECTIONS{ $self->[_VALUE_SR_IDX] } = $self->[_VALUE_SR_IDX] if $settle_is_rejection;
                }
                else {
                    bless $self->[_VALUE_SR_IDX], _RESOLUTION_CLASS;
                }
            }
        }
        else {

            # The callback errored, which means $self is now rejected.

            $new_value                    = $@;
            $value_sr_contents_is_promise = 0;

            bless $self->[_VALUE_SR_IDX], _REJECTION_CLASS();
            $_UNHANDLED_REJECTIONS{ $self->[_VALUE_SR_IDX] } = $self->[_VALUE_SR_IDX];
        }

        if (!$self_is_finally) {
            ${ $self->[_VALUE_SR_IDX] } = $new_value;
        }
    }
    else {

        # There was no handler from then(), so whatever state $final_value_sr
        # indicates # (i.e., resolution or rejection) is now $self’s state
        # as well.

        if ($self_is_finally) {
            $self->[_VALUE_SR_IDX] = $final_value_sr;
        }
        else {
            bless $self->[_VALUE_SR_IDX], ref($final_value_sr);
            ${ $self->[_VALUE_SR_IDX] } = $$final_value_sr;
        }

        $value_sr_contents_is_promise = UNIVERSAL::isa( $$final_value_sr, __PACKAGE__ );

        if ($settle_is_rejection) {
            $_UNHANDLED_REJECTIONS{ $self->[_VALUE_SR_IDX] } = $self->[_VALUE_SR_IDX];
        }
    }

    if ($value_sr_contents_is_promise) {
        return _repromise( @{$self}[ _VALUE_SR_IDX, _CHILDREN_IDX, _VALUE_SR_IDX ] );
    }

    if ( @{ $self->[_CHILDREN_IDX] } ) {
        $_->_settle( $self->[_VALUE_SR_IDX] ) for splice @{ $self->[_CHILDREN_IDX] };
    }

    return;
}

sub DESTROY {
    return if $$ != $_[0][_PID_IDX];

    if ( $_[0][_DETECT_LEAK_IDX] && ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT' ) {
        warn( ( '=' x 70 ) . "\n" . 'XXXXXX - ' . ref( $_[0] ) . " survived until global destruction; memory leak likely!\n" . ( "=" x 70 ) . "\n" );
    }

    if ( my $promise_value_sr = $_[0][_VALUE_SR_IDX] ) {
        if ( my $value_sr = delete $_UNHANDLED_REJECTIONS{$promise_value_sr} ) {
            my $ref = ref $_[0];
            warn "$ref: Unhandled rejection: $$value_sr";
        }
    }
}

1;