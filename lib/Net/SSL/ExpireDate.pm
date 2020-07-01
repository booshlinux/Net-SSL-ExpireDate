package Net::SSL::ExpireDate;

use strict;
use warnings;
use Carp;

our $VERSION = '1.21';

use base qw(Class::Accessor);
use Crypt::OpenSSL::X509 qw(FORMAT_ASN1);
use Date::Parse;
use DateTime;
use DateTime::Duration;
use Time::Duration::Parse;
use UNIVERSAL::require;

my $Socket = 'IO::Socket::INET6';
unless ( $Socket->require ) {
    $Socket = 'IO::Socket::INET';
    $Socket->require or die $@;
}

__PACKAGE__->mk_accessors(qw(type target));

my $SSL3_RT_CHANGE_CIPHER_SPEC = 20;
my $SSL3_RT_ALERT              = 21;
my $SSL3_RT_HANDSHAKE          = 22;
my $SSL3_RT_APPLICATION_DATA   = 23;

my $SSL3_MT_HELLO_REQUEST       = 0;
my $SSL3_MT_CLIENT_HELLO        = 1;
my $SSL3_MT_SERVER_HELLO        = 2;
my $SSL3_MT_CERTIFICATE         = 11;
my $SSL3_MT_SERVER_KEY_EXCHANGE = 12;
my $SSL3_MT_CERTIFICATE_REQUEST = 13;
my $SSL3_MT_SERVER_DONE         = 14;
my $SSL3_MT_CERTIFICATE_VERIFY  = 15;
my $SSL3_MT_CLIENT_KEY_EXCHANGE = 16;
my $SSL3_MT_FINISHED            = 20;

my $SSL3_AL_WARNING = 0x01;
my $SSL3_AL_FATAL   = 0x02;

my $SSL3_AD_CLOSE_NOTIFY            = 0;
my $SSL3_AD_UNEXPECTED_MESSAGE      = 10;    # fatal
my $SSL3_AD_BAD_RECORD_MAC          = 20;    # fatal
my $SSL3_AD_DECOMPRESSION_FAILURE   = 30;    # fatal
my $SSL3_AD_HANDSHAKE_FAILURE       = 40;    # fatal
my $SSL3_AD_NO_CERTIFICATE          = 41;
my $SSL3_AD_BAD_CERTIFICATE         = 42;
my $SSL3_AD_UNSUPPORTED_CERTIFICATE = 43;
my $SSL3_AD_CERTIFICATE_REVOKED     = 44;
my $SSL3_AD_CERTIFICATE_EXPIRED     = 45;
my $SSL3_AD_CERTIFICATE_UNKNOWN     = 46;
my $SSL3_AD_ILLEGAL_PARAMETER       = 47;    # fatal

sub new {
    my ( $class, %opt ) = @_;

    my $self = bless {
        type         => $opt{'type'}         ? $opt{'type'}         : undef,
        host         => $opt{'host'}         ? $opt{'host'}         : undef,
        port         => $opt{'port'}         ? $opt{'port'}         : undef,
        timeout      => $opt{'timeout'}      ? $opt{'timeout'}      : undef,
        ssl_hostname => $opt{'ssl_hostname'} ? $opt{'ssl_hostname'} : undef,
        file         => $opt{'file'}         ? $opt{'file'}         : undef,
    }, $class;

    if ( !$self->{'type'} ) {
        croak 'No type supplied';
    }

    # Only 2 options are allowed
    if ( ( $self->{'type'} ne 'socket' ) && ( $self->{'type'} ne 'file' ) ) {
        croak 'Invalid type: ' . $self->{'type'};
    }

    # User supplied 'file' as type, but did not supply a file
    if ( ( $self->{'type'} eq 'file' ) && ( !$self->{'file'} ) ) {
        croak 'No file supplied';
    }

    # User supplied 'socket' as type, but did not supply host or port
    if (   ( $self->{'type'} eq 'socket' )
        && ( ( !$self->{'port'} ) || ( !$self->{'host'} ) ) )
    {
        croak 'Missing port and/or host';
    }

    if ( !$opt{'timeout'} ) {

        # Defaults to 10 seconds
        $self->{'timeout'} = 10;
    }

    return $self;
}

sub get_cert {
    my $self = shift;

    if ( $self->{'type'} eq 'socket' ) {
        my $cert = eval { _peer_certificate($self); };
        if ($@) {
            warn $@;
        }
        if ( !$cert ) {
            return;
        }
        my $x509 = Crypt::OpenSSL::X509->new_from_string( $cert, FORMAT_ASN1 );
        my $begin_date_str  = $x509->notBefore;
        my $expire_date_str = $x509->notAfter;

        $self->{'expire_date'} =
          DateTime->from_epoch( epoch => str2time($expire_date_str) );
        $self->{'begin_date'} =
          DateTime->from_epoch( epoch => str2time($begin_date_str) );

        # Also return CN to verify correct certificate is being checked
        $self->{'subject'} =
          $x509->subject_name()->get_entry_by_type('CN')->as_string();

        return $self;
    }
    elsif ( $self->{'type'} eq 'file' ) {
        my $x509 = Crypt::OpenSSL::X509->new_from_file( $self->{'file'} );
        $self->{'expire_date'} =
          DateTime->from_epoch( epoch => str2time( $x509->notAfter ) );
        $self->{'begin_date'} =
          DateTime->from_epoch( epoch => str2time( $x509->notBefore ) );

        # Also return CN to verify correct certificate is being checked
        $self->{'subject'} =
          $x509->subject_name()->get_entry_by_type('CN')->as_string();

        return $self;
    }
    return;
}

*not_after  = \&expire_date;
*not_before = \&begin_date;

sub is_expired {
    my ( $self, $duration ) = @_;
    $duration ||= DateTime::Duration->new();

    if ( !$self->{begin_date} ) {
        $self->expire_date;
    }

    if ( !ref($duration) ) {    # if scalar
        $duration =
          DateTime::Duration->new( seconds => parse_duration($duration) );
    }

    my $dx = DateTime->now()->add_duration($duration);
    ### dx: $dx->iso8601

    return DateTime->compare( $dx, $self->{expire_date} ) >= 0 ? 1 : ();
}

sub _peer_certificate {
    my $self = shift;
    my $cert;

    no warnings 'once';
    no strict 'refs';    ## no critic
    *{ $Socket . '::write_atomically' } = sub {
        my ( $self, $data ) = @_;

        my $length    = length $data;
        my $offset    = 0;
        my $read_byte = 0;

        while ( $length > 0 ) {
            my $r = $self->syswrite( $data, $length, $offset ) || last;
            $offset    += $r;
            $length    -= $r;
            $read_byte += $r;
        }

        return $read_byte;
    };

    my $sock = {
        PeerAddr => $self->{'host'},
        PeerPort => $self->{'port'},
        Proto    => 'tcp',
        Timeout  => $self->{'timeout'},
    };

    $sock = $Socket->new(%$sock) or croak "cannot create socket: $!";
    _send_client_hello( $sock, $self->{'ssl_hostname'} );

    my $do_loop = 1;
    while ($do_loop) {
        my $record = _get_record($sock);
        if ( $record->{type} != $SSL3_RT_HANDSHAKE ) {
            if ( $record->{type} == $SSL3_RT_ALERT ) {
                my $d1 = unpack 'C', substr $record->{data}, 0, 1;
                my $d2 = unpack 'C', substr $record->{data}, 1, 1;
                if ( $d1 eq $SSL3_AL_WARNING ) {
                    ;    # go ahead
                }
                else {
                    croak "record type is SSL3_AL_FATAL. [desctioption: $d2]";
                }
            }
            else {
                croak "record type is not HANDSHAKE";
            }
        }

        while ( my $handshake = _get_handshake($record) ) {
            croak "too many loop" if $do_loop++ >= 10;
            if ( $handshake->{type} == $SSL3_MT_HELLO_REQUEST ) {
                ;
            }
            elsif ( $handshake->{type} == $SSL3_MT_CERTIFICATE_REQUEST ) {
                ;
            }
            elsif ( $handshake->{type} == $SSL3_MT_SERVER_HELLO ) {
                ;
            }
            elsif ( $handshake->{type} == $SSL3_MT_CERTIFICATE ) {
                my $data = $handshake->{data};
                my $len1 = $handshake->{length};
                my $len2 =
                  ( vec( $data, 0, 8 ) << 16 ) +
                  ( vec( $data, 1, 8 ) << 8 ) +
                  vec( $data, 2, 8 );
                my $len3 =
                  ( vec( $data, 3, 8 ) << 16 ) +
                  ( vec( $data, 4, 8 ) << 8 ) +
                  vec( $data, 5, 8 );
                croak "X509: length error" if $len1 != $len2 + 3;
                $cert = substr $data, 6;    # DER format
            }
            elsif ( $handshake->{type} == $SSL3_MT_SERVER_KEY_EXCHANGE ) {
                ;
            }
            elsif ( $handshake->{type} == $SSL3_MT_SERVER_DONE ) {
                $do_loop = 0;
            }
            else {
                ;
            }
        }

    }

    _sendalert( $sock, $SSL3_AL_FATAL, $SSL3_AD_HANDSHAKE_FAILURE ) or croak $!;
    $sock->close;

    return $cert;
}

sub _send_client_hello {
    my ( $sock, $servername ) = @_;

    my ( @buf, $len );
    ## record
    push @buf, $SSL3_RT_HANDSHAKE;
    push @buf, 3, 1;
    push @buf, undef, undef;
    my $pos_record_len = $#buf - 1;

    ## handshake
    push @buf, $SSL3_MT_CLIENT_HELLO;
    push @buf, undef, undef, undef;
    my $pos_handshake_len = $#buf - 2;

    ## ClientHello
    # client_version
    push @buf, 3, 3;

    # random
    my $time = time;
    push @buf, ( ( $time >> 24 ) & 0xFF );
    push @buf, ( ( $time >> 16 ) & 0xFF );
    push @buf, ( ( $time >> 8 ) & 0xFF );
    push @buf, ( ($time) & 0xFF );
    for ( 1 .. 28 ) {
        push @buf, int( rand(0xFF) );
    }

    # session_id
    push @buf, 0;

    # cipher_suites
    my @decCipherSuites = (
        49199, 49195, 49200, 49196, 158,   162,   163, 159, 49191, 49187,
        49171, 49161, 49192, 49188, 49172, 49162, 103, 51,  64,    107,
        56,    57,    49170, 49160, 156,   157,   60,  61,  47,    53,
        49186, 49185, 49184, 165,   161,   106,   105, 104, 55,    54,
        49183, 49182, 49181, 164,   160,   63,    62,  50,  49,    48,
        10,    136,   135,   134,   133,   132,   69,  68,  67,    66,
        65,
    );
    $len = scalar(@decCipherSuites) * 2;
    push @buf, ( ( $len >> 8 ) & 0xFF );
    push @buf, ( ($len) & 0xFF );
    foreach my $i (@decCipherSuites) {
        push @buf, ( ( $i >> 8 ) & 0xFF );
        push @buf, ( ($i) & 0xFF );
    }

    # compression
    push @buf, 1;
    push @buf, 0;

    # Extensions length
    my @ext = ( undef, undef );

    # Extension: server_name
    if ($servername) {

        # my $buf_len = scalar(@buf);
        # my $buf_len_pos = $#buf+1;
        # push @buf, undef, undef;

        # SNI (Server Name Indication)
        my $sn_len = length $servername;

        # Extension Type: Server Name
        push @ext, 0, 0;

        # Length
        push @ext, ( ( ( $sn_len + 5 ) >> 8 ) & 0xFF );
        push @ext, ( ( ( $sn_len + 5 ) ) & 0xFF );

        # Server Name Indication Length
        push @ext, ( ( ( $sn_len + 3 ) >> 8 ) & 0xFF );
        push @ext, ( ( ( $sn_len + 3 ) ) & 0xFF );

        # Server Name Type: host_name
        push @ext, 0;

        # Length of servername
        push @ext, ( ( $sn_len >> 8 ) & 0xFF );
        push @ext, ( ($sn_len) & 0xFF );

        # Servername
        for my $c ( split //, $servername ) {
            push @ext, ord($c);
        }
    }

    # Extension: supported_groups
    push @ext, 0x00, 0x0a;    # supported_groups
    my @supportedGroups = (
        0x000a,               # sect163r1
        0x0017,               # secp256r1
        0x0018,               # secp384r1
        0x0019,               # secp521r1
        0x001d,               # x25519
        0x001e,               # x448
    );
    $len = scalar(@supportedGroups) * 2;
    push @ext, ( ( $len >> 8 ) & 0xFF );
    push @ext, ( ($len) & 0xFF );
    foreach my $i (@supportedGroups) {
        push @ext, ( ( $i >> 8 ) & 0xFF );
        push @ext, ( ($i) & 0xFF );
    }

    # Extension: signature_algorithms (>= TLSv1.2)
    push @ext, 0x00, 0x0D;    # signature_algorithms
    push @ext, 0,    32;      # length
    push @ext, 0,    30;      # signature hash algorithms length
                              # enum {
          #     none(0), md5(1), sha1(2), sha224(3), sha256(4), sha384(5),
          #     sha512(6), (255)
          # } HashAlgorithm;

    for my $ha ( 2 .. 6 ) {

        # enum { anonymous(0), rsa(1), dsa(2), ecdsa(3), (255) }
        #   SignatureAlgorithm;
        for my $sa ( 1 .. 3 ) {
            push @ext, $ha, $sa;
        }
    }

    # Extension: Heartbeat
    push @ext, 0x00, 0x0F;    # heartbeat
    push @ext, 0x00, 0x01;    # length
    push @ext, 0x01;          # peer_allowed_to_send

    my $ext_len = scalar(@ext) - 2;
    if ( $ext_len > 0 ) {
        $ext[0] = ( ($ext_len) >> 8 ) & 0xFF;
        $ext[1] = ( ($ext_len) ) & 0xFF;
        push @buf, @ext;
    }

    # record length
    $len                        = scalar(@buf) - $pos_record_len - 2;
    $buf[$pos_record_len]       = ( ( $len >> 8 ) & 0xFF );
    $buf[ $pos_record_len + 1 ] = ( ($len) & 0xFF );

    # handshake length
    $len                           = scalar(@buf) - $pos_handshake_len - 3;
    $buf[$pos_handshake_len]       = ( ( $len >> 16 ) & 0xFF );
    $buf[ $pos_handshake_len + 1 ] = ( ( $len >> 8 ) & 0xFF );
    $buf[ $pos_handshake_len + 2 ] = ( ($len) & 0xFF );

    my $data;
    for my $c (@buf) {
        if ( $c =~ /^[0-9]+$/ ) {
            $data .= pack( 'C', $c );
        }
        else {
            $data .= $c;
        }
    }

    return $sock->write_atomically($data);
}

sub _get_record {
    my ($sock) = @_;

    my $record = {
        type    => -1,
        version => -1,
        length  => -1,
        read    => 0,
        data    => "",
    };

    $sock->read( $record->{type}, 1 ) or croak "cannot read type";
    $record->{type} = unpack 'C', $record->{type};

    $sock->read( $record->{version}, 2 ) or croak "cannot read version";
    $record->{version} = unpack 'n', $record->{version};

    $sock->read( $record->{length}, 2 ) or croak "cannot read length";
    $record->{length} = unpack 'n', $record->{length};

    $sock->read( $record->{data}, $record->{length} )
      or croak "cannot read data";

    return $record;
}

sub _get_handshake {
    my ($record) = @_;

    my $handshake = {
        type   => -1,
        length => -1,
        data   => "",
    };

    return if $record->{read} >= $record->{length};

    $handshake->{type} = vec( $record->{data}, $record->{read}++, 8 );
    return if $record->{read} + 3 > $record->{length};

    $handshake->{length} =
      ( vec( $record->{data}, $record->{read}++, 8 ) << 16 ) +
      ( vec( $record->{data}, $record->{read}++, 8 ) << 8 ) +
      ( vec( $record->{data}, $record->{read}++, 8 ) );

    if ( $handshake->{length} > 0 ) {
        $handshake->{data} =
          substr( $record->{data}, $record->{read}, $handshake->{length} );
        $record->{read} += $handshake->{length};
        return if $record->{read} > $record->{length};
    }
    else {
        $handshake->{data} = undef;
    }

    return $handshake;
}

sub _sendalert {
    my ( $sock, $level, $desc ) = @_;

    my $data = "";

    $data .= pack( 'C', $SSL3_RT_ALERT );
    $data .= pack( 'C', 3 );
    $data .= pack( 'C', 0 );
    $data .= pack( 'C', 0 );
    $data .= pack( 'C', 2 );
    $data .= pack( 'C', $level );
    $data .= pack( 'C', $desc );

    return $sock->write_atomically($data);
}

1;    # Magic true value required at end of module
__END__

=head1 NAME

Net::SSL::ExpireDate - obtain expiration date of certificate

=head1 SYNOPSIS

    use Net::SSL::ExpireDate;

    my $ed = Net::SSL::ExpireDate->new(
		type         => 'socket',
		host         => '192.168.1.1',
		ssl_hostname => 'example.com',
		port         => 10993,
		timeout      => 5,
	);
    my $ed = Net::SSL::ExpireDate->new( file  => '/etc/ssl/cert.pem' );

    if (my $cert = $ed->get_cert) {
      # do something
      $expire_date = $cert->{'expire_date'};         # return DateTime instance

      $expired = $cert->is_expired;              # examine already expired

      $expired = $cert->is_expired('2 months');  # will expire after 2 months
      $expired = $cert->is_expired(DateTime::Duration->new(months=>2));  # ditto
    }

=head1 DESCRIPTION

Net::SSL::ExpireDate get certificate from network (SSL) or local
file and obtain its expiration date.

=head1 METHODS

=head2 new

  $ed = Net::SSL::ExpireDate->new( %option )

This method constructs a new "Net::SSL::ExpireDate" instance and
returns it. %option is to specify certificate.

  KEY          VALUE
  --------------------------------------
  host         "IP address or hostname"
  ssl_hostname "Hostname to send for SNI"
  type         "socket|file"
  file         "path/to/certificate"
  timeout      "Timeout in seconds"

=head2 get_cert

  $cert = $ed->get_cert;
  print $cert->{'subject'};
  print $cert->{'expire_date'};
  print $cert->{'begin_date'};

Return object of certificate info

=head2 is_expired

  $expired = $ed->is_expired;

Obtain already expired or not.

You can specify interval to obtain will expire on the future time.
Acceptable intervals are human readable string (parsed by
"Time::Duration::Parse") and "DateTime::Duration" instance.

  # will expire after 2 months
  $expired = $ed->is_expired('2 months');
  $expired = $ed->is_expired(DateTime::Duration->new(months=>2));

=head2 type

return type of examinee certificate. "socket" or "file".

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-net-ssl-expiredate@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.

=head1 AUTHOR

HIROSE Masaaki E<lt>hirose31 _at_ gmail.comE<gt>

=head1 REPOSITORY

L<http://github.com/hirose31/net-ssl-expiredate>

  git clone git://github.com/hirose31/net-ssl-expiredate.git

patches and collaborators are welcome.

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright HIROSE Masaaki

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

