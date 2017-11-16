# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4

# This file is part of Sympa, see top-level README.md file for details

package Sympa::Request::Handler::add;

use strict;
use warnings;
use Time::HiRes qw();

use Sympa;
use Conf;
use Sympa::Language;
use Sympa::Log;
use Sympa::Tools::Password;
use Sympa::User;

use base qw(Sympa::Request::Handler);

my $language = Sympa::Language->instance;
my $log      = Sympa::Log->instance;

use constant _action_scenario => 'add';
use constant _action_regexp   => qr'reject|request_auth|do_it'i;
use constant _context_class   => 'Sympa::List';

# Old name: Sympa::Commands::add().
sub _twist {
    my $self    = shift;
    my $request = shift;

    my $list    = $request->{context};
    my $which   = $list->{'name'};
    my $robot   = $list->{'domain'};
    my $sender  = $request->{sender};
    my $email   = $request->{email};
    my $comment = $request->{gecos};

    $language->set_lang($list->{'admin'}{'lang'});

    unless (Sympa::Tools::Text::valid_email($email)) {
        $self->add_stash($request, 'user', 'incorrect_email',
            {'email' => $email});
        $log->syslog('err',
            'ADD command rejected; incorrect email "%s"', $email);
        return undef;
    }

    if ($list->is_list_member($email)) {
        $self->add_stash($request, 'user', 'already_subscriber',
            {'email' => $email});
        $log->syslog('err',
            'ADD command rejected; user "%s" already member of list "%s"',
            $email, $which);
        return undef;
    }

    unless ($request->{force}) {
        # If a list is not 'open' and allow_subscribe_if_pending has been set
        # to 'off' returns undef.
        unless ($list->{'admin'}{'status'} eq 'open'
            or Conf::get_robot_conf($list->{'domain'},
                'allow_subscribe_if_pending') eq 'on'
            ) {
            $self->add_stash($request, 'user', 'list_not_open',
                {'status' => $list->{'admin'}{'status'}});
            $log->syslog('info', 'List %s not open', $list);
            return undef;
        }
    }

    my $u;
    my $defaults = $list->get_default_user_options();
    %{$u} = %{$defaults};
    $u->{'email'} = $email;
    $u->{'gecos'} = $comment;
    $u->{'date'}  = $u->{'update_date'} = time;

    $list->add_list_member($u);
    if (defined $list->{'add_outcome'}{'errors'}) {
        if (defined $list->{'add_outcome'}{'errors'}
            {'max_list_members_exceeded'}) {
            $self->add_stash($request, 'user', 'max_list_members_exceeded',
                {max_list_members => $list->{'admin'}{'max_list_members'}});
        } else {
            my $error =
                sprintf 'Unable to add user %s in list %s : %s',
                $u, $list->get_id,
                $list->{'add_outcome'}{'errors'}{'error_message'};
            Sympa::send_notify_to_listmaster(
                $list,
                'mail_intern_error',
                {   error  => $error,
                    who    => $sender,
                    action => 'Command process',
                }
            );
            $self->add_stash($request, 'intern');
        }
        return undef;
    }

    $self->add_stash($request, 'notice', 'now_subscriber',
        {'email' => $email});

    my $user = Sympa::User->new($email);
    $user->lang($list->{'admin'}{'lang'}) unless $user->lang;
    $user->password(Sympa::Tools::Password::tmp_passwd($email))
        unless $user->password;
    $user->save;

    ## Now send the welcome file to the user if it exists and notification
    ## is supposed to be sent.
    unless ($request->{quiet}) {
        unless ($list->send_probe_to_user('welcome', $email)) {
            $log->syslog('notice', 'Unable to send "welcome" probe to %s',
                $email);
        }
    }

    $log->syslog(
        'info',
        'ADD %s %s from %s accepted (%.2f seconds, %d subscribers)',
        $which,
        $email,
        $sender,
        Time::HiRes::time() - $self->{start_time},
        $list->get_total()
    );
    if ($request->{notify}) {
        $list->send_notify_to_owner(
            'notice',
            {   'who'     => $email,
                'gecos'   => $comment,
                'command' => 'add',
                'by'      => $sender
            }
        );
    }
    return 1;
}

1;
__END__

=encoding utf-8

=head1 NAME

Sympa::Request::Handler::add - add request handler

=head1 DESCRIPTION

Adds a user to a list (requested by another user). Verifies
the proper authorization and sends acknowledgements unless
quiet add.

=head2 Attributes

See also L<Sympa::Request/"Attributes">.

=over

=item {email}

I<Mandatory>.
E-mail of the user to be added.

=item {force}

I<Optional>.
If true value is specified,
users will be added even if the list is closed.

=item {gecos}

I<Optional>.
Display name of the user to be added.

=item {quiet}

I<Optional>.
Don't notify addition to the user.

=back

=head1 SEE ALSO

L<Sympa::Request::Handler>.

=head1 HISTORY

=cut
