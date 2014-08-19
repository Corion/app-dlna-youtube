package HTTP::Logger::Win32;
use strict;
use Win32::Console;
use Carp qw( croak );

sub new {
    my( $class, %options )= @_;
    $options{ id }||= 0;
    $options{ requests }||= {};
    $options{ console }||= Win32::Console->new;
    #$options{ outfh }||= \*main::STDOUT;
    
    #$options{ outfh_tie }= tie *main::STDOUT, 'HTTP::Logger::Win32::Handle', delegate => $options{ outfh };
    
    bless \%options => $class;
};

sub next_id { $_[0]->{ id }++ };
sub requests { $_[0]->{ requests } };

sub console { $_[0]->{console} };

sub cursor_pos {
    my( $self )= @_;
    my( $x,$y )= $self->console->Cursor;
    ($x,$y)
};

sub term_size {
    my( $self )= @_;
    my( $w,$h )= $self->console->Size;
    ($w,$h)
};

sub requests_as_lines {
    my( $self, $requests ) = @_;
    $requests ||= $self->requests;
    
    my( $w, undef )= $self->term_size;
    my @lines= ('');
    
    for (sort keys %$requests) {
        my $item= sprintf "%2d: %010d", $requests->{ $_ }->{desc},$requests->{ $_ }->{bytes_read};
        
        $item= (length $lines[ -1 ] ? '  ' : '') . $item;

        if(     length $lines[-1] > 0 # We already have content
            and length $lines[-1] + length( $item ) >= $w ) {
            # Begin a new line
            push @lines, '';
        };
        $lines[ -1 ] .= $item;
    };
    @lines
};

# Logging routine that shows all active requests
sub display_requests {
    my( $self )= @_;
    
    my @lines= $self->requests_as_lines;
    my $logger;
    if(     $logger= tied $self->{ outfh_tie } 
        and $logger->is_clean) {
        # Rewind and overprint
        $self->console->Cursor( $self->{old_x}, $self->{old_y} );
    };
    print join "\n", @lines;
    print "\n";
    if( $logger ) {
        # Recalculate the starting pos of the output
        my( $x,$y )= $self->cursor_pos;
        $self->{ old_x }= $x;
        $self->{ old_y }= $y - @lines;
        
        $logger->set_clean();
    };
};

sub add_request {
    my($self,$desc) = @_;
    my $id= $self->next_id;
    $self->requests->{id}= {
        desc => sprintf( "%02d %s", $id, $desc ),
        bytes_read => 0,
        last_time => time(),
    };
    $self->display_requests;
    return $id
};

sub update_request {
    my($self,$id,$new_bytes_read) = @_;
    my $request= $self->requests->{id}
        or croak "Unknown request id '$id'";
    $request->{bytes_read} += $new_bytes_read;
    $request->{last_time}= time();
    $self->display_requests;
};

sub remove_request {
    my($self,$id) = @_;
    delete $self->requests->{id}
        or croak "Unknown request id '$id'";
    $self->display_requests;
};

package HTTP::Logger::Win32::Handle;
use parent 'Tie::Handle';
use Carp qw(croak);

use vars qw($AUTOLOAD);

sub new {
    my( $class, %options )= @_;
    croak "No handle to delegate to"
        unless $options{ delegate };
    $options{ dirty }||= 0;
    bless \%options => $class;
};

sub TIEHANDLE {
    my( $class, %options )= @_;
    $class->new(
        #delegate => tied(),
        %options
    );
};

sub AUTOLOAD {
    my($self)= $_[0];
    (my $method)= $AUTOLOAD=~ m/::([^:]+)$/
        or die "Invalid method in '$AUTOLOAD'";
    goto &{ $self->delegate( $method ) };
};

sub delegate {
    my( $self, $method )= @_;
    my $dispatch= $self->{delegate}->can( $method )
        or croak "Delegate $self->{delegate} does not implement method '$method'";
}

sub is_dirty { $_[0]->{dirty} };
sub is_clean { !$_[0]->{dirty} };
sub set_clean { $_[0]->{dirty}= 0 };

sub PRINT {
    my( $self, @args )= @_;
    $self->{dirty}||= 1;
    goto &{ $self->delegate('PRINT') };
}

sub WRITE {
    my( $self, @args )= @_;
    $self->{dirty}||= 1;
    goto &{ $self->delegate('WRITE') };
}

sub DESTROY {};

1;