# Declare our package
package POE::Component::Lightspeed::Server;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
our $VERSION = '0.01';

# Import what we need
use Carp qw( croak );
use Socket qw( inet_ntoa );
use Time::HiRes qw( gettimeofday );
use POE;
use POE::Wheel::SocketFactory;
use POE::Wheel::ReadWrite;
use POE::Driver::SysRW;
use POE::Filter::Line;
use POE::Filter::Reference;
use POE::Component::Lightspeed::Router;
use POE::Component::Lightspeed::Constants qw( MSG_TIMESTAMP MSG_ACTION );

# Set some constants
BEGIN {
	# Debug fun!
	if ( ! defined &DEBUG ) {
		eval "sub DEBUG () { 0 }";
	} elsif ( DEBUG ) {
		require Data::Dumper;
	}
}

# Spawns an instance of the server
sub spawn {
	# Get the OOP's type
	my $type = shift;

	# Sanity checking
	if ( @_ & 1 ) {
		croak( 'POE::Component::Lightspeed::Server->spawn needs even number of options' );
	}

	# The options hash
	my %opt = @_;

	# Our own options
	my ( $ALIAS, $KERNEL, $ADDRESS, $PORT, $SERIALIZERS, $COMPRESSION );

	# Get the session alias
	if ( exists $opt{'ALIAS'} and defined $opt{'ALIAS'} and length( $opt{'ALIAS'} ) ) {
		$ALIAS = delete $opt{'ALIAS'};
	} else {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default ALIAS = lightspeed_server';
		}

		# Set the default
		$ALIAS = 'lightspeed_server';

		# Remove any lingering ALIAS
		if ( exists $opt{'ALIAS'} ) {
			delete $opt{'ALIAS'};
		}
	}

	# Get the KERNEL
	if ( exists $opt{'KERNEL'} and defined $opt{'KERNEL'} and length( $opt{'KERNEL'} ) ) {
		$KERNEL = delete $opt{'KERNEL'};
	} else {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default KERNEL = Supplied by POE';
		}

		# Set the default
		$KERNEL = $poe_kernel->ID;

		if ( exists $opt{'KERNEL'} ) {
			delete $opt{'KERNEL'};
		}
	}

	# Get the ADDRESS
	if ( exists $opt{'ADDRESS'} and defined $opt{'ADDRESS'} and length( $opt{'ADDRESS'} ) ) {
		$ADDRESS = delete $opt{'ADDRESS'};
	} else {
		warn 'POE::Component::Lightspeed::Server->spawn must get at least 1 argument - the address to connect!';
		return undef;
	}

	# Get the PORT
	if ( exists $opt{'PORT'} and defined $opt{'PORT'} and length( $opt{'PORT'} ) ) {
		$PORT = delete $opt{'PORT'};
	} else {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default PORT = 9876';
		}

		# Set the default
		$PORT = 9876;

		if ( exists $opt{'PORT'} ) {
			delete $opt{'PORT'};
		}
	}

	# Create the POE Session!
	POE::Session->create(
		'inline_states'	=>	{
			# Generic stuff
			'_start'		=>	\&StartServer,
			'_stop'			=>	sub {},

			# Public interface
			'shutdown'		=>	\&StopServer,

			# SocketFactory events
			'GotConnection'		=>	\&GotConnection,
			'SFError'		=>	\&SFError,

			# ReadWrite events
			'InputLine'		=>	\&InputLine,
			'InputHash'		=>	\&InputHash,
			'Flushed'		=>	\&RWFlush,
			'RWError'		=>	\&RWError,

			# Router events
			'send'			=>	\&Send_Packet,
			'killclient'		=>	\&KillClient,
		},

		# Our own heap
		'heap'		=>	{
			'ALIAS'		=>	$ALIAS,
			'ADDRESS'	=>	$ADDRESS,
			'PORT'		=>	$PORT,

			# Our ReadWrite wheels here
			'RW'		=>	{},

			# The socketfactory itself
			'SF'		=>	undef,

			# Our kernel name
			'MYKERNEL'	=>	$KERNEL,

			# Are we shutting down?
			'SHUTDOWN'	=>	0,
		},
	) or die 'Unable to create a new session!';

	# Spawn the Router session
	POE::Component::Lightspeed::Router->spawn();

	# Return success
	return 1;
}

# Starts listening for other lightspeed connections
sub StartServer {
	# Set the alias
	$_[KERNEL]->alias_set( $_[HEAP]->{'ALIAS'} );

	# Okay, time to create the server!
	$_[HEAP]->{'SF'} = POE::Wheel::SocketFactory->new(
		'BindPort'	=>	$_[HEAP]->{'PORT'},
		'BindAddress'	=>	$_[HEAP]->{'ADDRESS'},
		'Reuse'		=>	'yes',
		'SuccessEvent'	=>	'GotConnection',
		'FailureEvent'	=>	'SFError',
	);

	# All done!
	return 1;
}

# Shuts ourself down
sub StopServer {
	# Remove the alias
	$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );

	# Shutdown the listening socket
	delete $_[HEAP]->{'SF'};

	# We are shutting down...
	$_[HEAP]->{'SHUTDOWN'} = 1;

	# Broadcast to the entire network that we are going down
	$_[KERNEL]->call(
		$POE::Component::Lightspeed::Router::SES_ALIAS,
		'killserver',
		[ keys %{ $_[HEAP]->{'RW'} } ],
	);

	# All done!
	return 1;
}

# Shuts down a client
sub KillClient {
	# Get the wheel id
	my $id = $_[ARG0];

	# Delete that wheel
	if ( exists $_[HEAP]->{'RW'}->{ $id } ) {
		delete $_[HEAP]->{'RW'}->{ $id };
	}

	# All done!
	return 1;
}

# Got a connection from another lightspeed client!
sub GotConnection {
	# ARG0 = Socket, ARG1 = Remote Address, ARG2 = Remote Port, ARG3 = wheelid
	my( $socket, $id ) = @_[ ARG0, ARG3 ];

	# Set up the Wheel to read from the socket
	my $wheel = POE::Wheel::ReadWrite->new(
		'Handle'	=>	$socket,
		'Driver'	=>	POE::Driver::SysRW->new(),
		'Filter'	=>	POE::Filter::Line->new(),
		'InputEvent'	=>	'InputLine',
		'FlushedEvent'	=>	'Flushed',
		'ErrorEvent'	=>	'RWError',
	);

	# Save this wheel!
	$_[HEAP]->{'RW'}->{ $wheel->ID } = {
		'WHEEL'		=>	$wheel,
		'PHASE'		=>	'no',
		'COMPRESSION'	=>	0,
		'FILTER'	=>	undef,
		'REMOTE_IP'	=>	inet_ntoa( $_[ARG1] ),
		'REMOTE_PORT'	=>	$_[ARG2],
		'CLIENT_VER'	=>	undef,
		'CLIENT_KERNEL'	=>	undef,
		'PACKETS_IN'	=>	0,
		'PACKETS_OUT'	=>	0,
	};

	# Send the welcome line
	$wheel->put( 'SERVER Lightspeed v/' . $VERSION . ' kernel ' . $_[HEAP]->{'MYKERNEL'} );

	# Debug stuff
	if ( DEBUG ) {
		warn "GotConnection completed creation of ReadWrite wheel ( " . $wheel->ID . " )";
	}

	# Success!
	return 1;
}

# Got some sort of error from SocketFactory
sub SFError {
	# ARG0 = operation, ARG1 = error number, ARG2 = error string, ARG3 = wheel ID
	my ( $operation, $errnum, $errstr, $wheel_id ) = @_[ ARG0 .. ARG3 ];

	# Debug stuff
	if ( DEBUG ) {
		warn "SocketFactory Wheel $wheel_id generated $operation error $errnum: $errstr\n";
	}

	# Success!
	return 1;
}

# Got some input!
sub InputLine {
	# ARG0 = input, ARG1 = wheel id
	my( $line, $id ) = @_[ ARG0, ARG1 ];

	# Skip empty lines
	return if $line eq '';

	# Ok, what stage of negotiations are we on?
	if ( $_[HEAP]->{'RW'}->{ $id }->{'PHASE'} eq 'no' ) {
		# Should be the welcome line
		if ( $line =~ /^CLIENT\s+Lightspeed\s+v\/(.*)\s+kernel\s+(.*)$/ ) {
			# Okay, this client talks lightspeed :)
			$_[HEAP]->{'RW'}->{ $id }->{'PHASE'} = 'compression';
			$_[HEAP]->{'RW'}->{ $id }->{'CLIENT_VER'} = $1;
			$_[HEAP]->{'RW'}->{ $id }->{'CLIENT_KERNEL'} = $2;
		} else {
			# Doesn't talk lightspeed?
			if ( DEBUG ) {
				warn "Client doesn't talk Lightspeed -> input was: $line";
			}

			delete $_[HEAP]->{'RW'}->{ $id };
			return undef;
		}
	} elsif ( $_[HEAP]->{'RW'}->{ $id }->{'PHASE'} eq 'compression' ) {
		# Should be the compress line
		if ( $line =~ /^COMPRESSION (ON|OFF)$/ ) {
			# On or off?
			if ( $1 eq 'ON' ) {
				$_[HEAP]->{'RW'}->{ $id }->{'COMPRESSION'} = 1;
			} else {
				$_[HEAP]->{'RW'}->{ $id }->{'COMPRESSION'} = 0;
			}

			# Move on to the next phase
			$_[HEAP]->{'RW'}->{ $id }->{'WHEEL'}->put( 'COMPRESSION OK' );
			$_[HEAP]->{'RW'}->{ $id }->{'PHASE'} = 'serializer';
		} else {
			# Doesn't talk lightspeed?
			if ( DEBUG ) {
				warn "Client doesn't talk Lightspeed -> input was: $line";
			}

			delete $_[HEAP]->{'RW'}->{ $id };
			return undef;
		}
	} elsif ( $_[HEAP]->{'RW'}->{ $id }->{'PHASE'} eq 'serializer' ) {
		# Should be the serializer line
		if ( $line =~ /^SERIALIZER (.*)$/ ) {
			# Let's see if it is a valid serializer
			eval { $_[HEAP]->{'RW'}->{ $id }->{'FILTER'} = POE::Filter::Reference->new( $1, $_[HEAP]->{'RW'}->{ $id }->{'COMPRESSION'} ) };

			# Check for errors
			if ( $@ ) {
				$_[HEAP]->{'RW'}->{ $id }->{'WHEEL'}->put( 'SERIALIZER NOT OK' );
			} else {
				$_[HEAP]->{'RW'}->{ $id }->{'WHEEL'}->put( 'SERIALIZER OK' );
				$_[HEAP]->{'RW'}->{ $id }->{'PHASE'} = 'done';
			}
		} else {
			# Doesn't talk lightspeed?
			if ( DEBUG ) {
				warn "Client doesn't talk Lightspeed -> input was: $line";
			}

			delete $_[HEAP]->{'RW'}->{ $id };
			return undef;
		}
	} elsif ( $_[HEAP]->{'RW'}->{ $id }->{'PHASE'} eq 'done' ) {
		# Should be the "negotiation complete" line
		if ( $line eq 'DONE' ) {
			# Allright!
			$_[HEAP]->{'RW'}->{ $id }->{'WHEEL'}->event( 'InputEvent', 'InputHash' );
			$_[HEAP]->{'RW'}->{ $id }->{'WHEEL'}->set_filter( $_[HEAP]->{'RW'}->{ $id }->{'FILTER'} );

			# Let the Router know a link is up
			$_[KERNEL]->call( $POE::Component::Lightspeed::Router::SES_ALIAS, 'link_up', $id, $_[HEAP]->{'MYKERNEL'}, $_[HEAP]->{'RW'}->{ $id }->{'CLIENT_KERNEL'}, 'Server' );
		} else {
			# Doesn't talk lightspeed?
			if ( DEBUG ) {
				warn "Client doesn't talk Lightspeed -> input was: $line";
			}

			delete $_[HEAP]->{'RW'}->{ $id };
			return undef;
		}
	}

	# All done!
	return 1;
}

# The main method of communication
sub InputHash {
	# ARG0 = data, ARG1 = wheel id
	my( $msg, $id ) = @_[ ARG0, ARG1 ];

	if ( DEBUG ) {
		warn "Received packet from link $id:\n" . Data::Dumper::Dumper( $msg );
	}

	# Send it off to the Router!
	$_[KERNEL]->post( $POE::Component::Lightspeed::Router::SES_ALIAS, 'ACTION_' . $msg->[ MSG_ACTION ], $msg, $id );

	# Increment the packet count
	$_[HEAP]->{'RW'}->{ $id }->{'PACKETS_IN'}++;

	# All done!
	return 1;
}

# ReadWrite error
sub RWError {
	# ARG0 = operation, ARG1 = error number, ARG2 = error string, ARG3 = wheel ID
	my ( $operation, $errnum, $errstr, $wheel_id ) = @_[ ARG0 .. ARG3 ];

	# Debug stuff
	if ( DEBUG ) {
		warn "ReadWrite Wheel $wheel_id generated $operation error $errnum: $errstr\n";
	}

	# Let the router know a link is down
	$_[KERNEL]->call( $POE::Component::Lightspeed::Router::SES_ALIAS, 'link_down', $wheel_id );

	# Delete this wheel
	delete $_[HEAP]->{'RW'}->{ $wheel_id };

	# Success!
	return 1;
}

# ReadWrite flush event
sub RWFlush {
	# ARG0 = wheel id

	# Are we shutting down?
	if ( $_[HEAP]->{'SHUTDOWN'} ) {
		# Delete this wheel
		delete $_[HEAP]->{'RW'}->{ $_[ARG0] };
	}

	# All done!
	return 1;
}

# Sends a packet down the wire
sub Send_Packet {
	my( $id, $packet ) = @_[ ARG0, ARG1 ];

	# Sanity check
	if ( ! defined $_[HEAP]->{'RW'}->{ $id }->{'WHEEL'} ) {
		if ( DEBUG ) {
			warn "Link $id is down, unable to send packet!";
		}
		return undef;
	}

	# Add the timestamp
	if ( ! defined $packet->[ MSG_TIMESTAMP ] ) {
		$packet->[ MSG_TIMESTAMP ] = gettimeofday();
	}

	if ( DEBUG ) {
		warn "Sending packet to link $id:\n" . Data::Dumper::Dumper( $packet );
	}

	# Send it to the proper RW wheel!
	$_[HEAP]->{'RW'}->{ $id }->{'WHEEL'}->put( $packet );

	# Increment the packet count
	$_[HEAP]->{'RW'}->{ $id }->{'PACKETS_OUT'}++;

	# All done!
	return 1;
}

# End of module
1;
__END__

=head1 NAME

POE::Component::Lightspeed::Server - The "hubs" of the Lightspeed network

=head1 SYNOPSIS

	use POE;
	use POE::Component::Lightspeed::Server;

	POE::Component::Lightspeed::Server->spawn(
		'ALIAS'		=>	'myclient',
		'KERNEL'	=>	'mybox',
		'ADDRESS'	=>	'localhost',
		'PORT'		=>	5634,
		'SERIALIZERS'	=>	[ qw( MySerializer Storable ) ],
		'COMPRESSION'	=>	1,
	) or die "Unable to create Server session!";

	# Communicate with the rest of the network once they connect!

=head1 ABSTRACT

	The Lightspeed Server session

=head1 CHANGES

=head2 0.01

	Initial Revision

=head1 DESCRIPTION

This module listens for connections from remote Lightspeed clients. Usage is exactly the same as described in the Lightspeed documentation.

=head2 Starting Lightspeed::Server

To start the server, just call it's spawn method:

	POE::Component::Lightspeed::Server->spawn(
		'ALIAS'		=>	'myclient',
		'KERNEL'	=>	'mybox',
		'ADDRESS'	=>	'localhost',
		'PORT'		=>	5634,
		'SERIALIZERS'	=>	[ qw( MySerializer Storable ) ],
		'COMPRESSION'	=>	1,
	) or die "Unable to create Server session!";

This method will return undef on error or return success.

This constructor accepts only 6 options.

=over 4

=item C<ADDRESS>

The address to listen on.

This is the only MANDATORY argument.

=item C<ALIAS>

This will set the alias this client session uses in the POE Kernel.

This will default to "lightspeed_server" or "lightspeed_serverX" where x is a number sequence.

=item C<PORT>

The port to listen on.

This will default to '9876'.

=item C<KERNEL>

The descriptive name of the local kernel.

This will default to $POE::Kernel::poe_kernel->ID().

=item C<SERIALIZERS>

This should be an arrayref of serializers to use

This will default to:
	[ qw( Storable YAML ) ]

=item C<COMPRESSION>

This is the boolean option passed to POE::Filter::Reference

This will default to false ( 0 )

=back

=head2 Usage

The Server session will listen for connections and announce them to the Lightspeed network. Then, message-passing operations can BEGIN!

It's pretty strict about the initial connection to the client, and will disconnect them if it finds any errors.

=head2 Commands

There's only one command you can send: the shutdown event.

Keep in mind that you need the alias of the session if you have several of them running!
	$kernel->post( 'lightspeed_server', 'shutdown' );

=head2 Notes

This module is very picky about capitalization!

All of the options are uppercase, to avoid confusion.

You can enable debugging mode by doing this:

	sub POE::Component::Lightspeed::Server::DEBUG () { 1 }
	use POE::Component::Lightspeed::Server;

=head1 EXPORT

Nothing.

=head1 SEE ALSO

L<POE::Component::Lightspeed>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2005 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
