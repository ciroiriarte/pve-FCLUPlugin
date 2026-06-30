package PVE::Storage::FCLU::Credentials;

use strict;
use warnings;

use JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Carp qw(croak);

# Per-storage array credential store (ARCHITECTURE.md §7, §9 Phase 1). Generalized
# verbatim from the Hitachi Config.pm credential helpers — it is wholly
# vendor-neutral: a username/password pair persisted as 0600 JSON, one file per
# storeid. The ONLY Hitachi-specific detail was the directory, so the base dir is
# now a constructor knob defaulting to the framework namespace.
#
# On a real node BASE_DIR lives under /etc/pve/priv (pmxcfs, replicated, root-only);
# unit tests pass base_dir => a tempdir, so no path monkey-patching is needed.

# Framework credential namespace under PVE's private, replicated config tree.
use constant DEFAULT_BASE_DIR => '/etc/pve/priv/fclu';

sub new {
    my ($class, %opts) = @_;

    croak "storeid is required" unless $opts{storeid};

    return bless {
        storeid  => $opts{storeid},
        base_dir => $opts{base_dir} // DEFAULT_BASE_DIR,
    }, $class;
}

sub store {
    my ($self, $username, $password) = @_;

    croak "username is required" unless defined $username && length $username;
    croak "password is required" unless defined $password && length $password;

    my $file = $self->_creds_file();
    my $dir  = dirname($file);
    make_path($dir) unless -d $dir;

    # Create with restrictive perms BEFORE writing the secret: open the file, lock
    # its mode to 0600, then emit the JSON so the password is never world-readable
    # for even a moment.
    open( my $fh, '>', $file ) or croak "Cannot write credentials to $file: $!";
    chmod( 0600, $file );
    print $fh encode_json( { username => $username, password => $password } );
    close($fh);

    return 1;
}

sub read {
    my ($self) = @_;

    my $file = $self->_creds_file();
    croak "Credentials file not found: $file" unless -f $file;

    open( my $fh, '<', $file ) or croak "Cannot read credentials from $file: $!";
    local $/;
    my $content = <$fh>;
    close($fh);

    my $creds = decode_json($content);
    croak "Invalid credentials file: missing username" unless $creds->{username};
    croak "Invalid credentials file: missing password" unless $creds->{password};

    return ( $creds->{username}, $creds->{password} );
}

sub delete {
    my ($self) = @_;

    my $file = $self->_creds_file();
    unlink($file) if -f $file;

    return 1;
}

# ── Internal ──

sub _creds_file {
    my ($self) = @_;
    return "$self->{base_dir}/$self->{storeid}.creds";
}

1;
