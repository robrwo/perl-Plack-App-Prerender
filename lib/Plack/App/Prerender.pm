package Plack::App::Prerender;

# ABSTRACT: a simple prerendering proxy for Plack

use v5.10;
use strict;
use warnings;

our $VERSION = 'v0.1.0';

use parent qw/ Plack::Component /;

use Encode qw/ encode /;
use HTTP::Headers;
use HTTP::Request;
use HTTP::Status qw/ :constants /;
use Plack::Request;
use Plack::Util;
use Plack::Util::Accessor qw/ mech base cache max_age request response /;
use Time::Seconds qw/ ONE_HOUR /;
use WWW::Mechanize::Chrome;

# RECOMMEND PREREQ: CHI
# RECOMMEND PREREQ: Log::Log4perl

=head1 SYNOPSIS

  use CHI;
  use Log::Log4perl qw/ :easy /;
  use Plack::App::Prerender;

  my $cache = CHI->new(
      driver   => 'File',
      root_dir => '/tmp/test-chi',
  );

  Log::Log4perl->easy_init($ERROR);

  my $app = Plack::App::Prerender->new(
      base  => "http://www.example.com",
      cache => $cache,
  )->to_app;

=head1 DESCRIPTION

This is a PSGI application that acts as a simple prerendering proxy
for websites using Chrone.

This only supports GET requests, as this is intended as a proxy for
search engines that do not support AJAX-generated content.

=attr mech

A L<WWW::Mechanize::Chrome> object. If omitted, a headless instance of
Chrome will be launched.

=attr base

This is the base URL prefix.

=attr cache

This is the cache handling interface. See L<CHI>.

=attr max_age

This is the maximum time (in seconds) to cache content.  If the page
returns a C<Cache-Control> header with a C<max-age>, then that will be
used instead.

=attr request

This is an array reference of request headers to pass through the
proxy.

=attr response

This is an array reference of response headers to pass from the
result.

=head1 LIMITATIONS

This does not support cache invalidation or screenshot rendering.

=cut

sub prepare_app {
    my ($self) = @_;

    unless ($self->mech) {

        my $mech = WWW::Mechanize::Chrome->new(
            headless         => 1,
            separate_session => 1,
            launch_arg => [qw/ --start-maximized /],
        );

        $self->mech($mech);

        $SIG{INT} = sub {
            $self->DESTROY;
            exit(1);
        };

    }

    unless ($self->request) {
        $self->request(
            [
             qw/
             User-Agent
             X-Forwarded-For
             X-Forwarded-Host
             X-Forwarded-Port
             X-Forwarded-Proto
             /
            ]
        );
    }

    unless ($self->response) {
        $self->response(
            [
             qw/
             Content-Type
             Expires
             Last-Modified
             /
            ]
        );
    }

    unless ($self->max_age) {
        $self->max_age( ONE_HOUR );
    }
}

sub call {
    my ($self, $env) = @_;

    my $req = Plack::Request->new($env);

    my $method = $req->method // '';
    unless ($method eq "GET") {
        return [ HTTP_METHOD_NOT_ALLOWED ];
    }

    my $path_query = $env->{REQUEST_URI};

    my $cache = $self->cache;
    my $data  = $cache->get($path_query);
    if (defined $data) {

        return $data;

    }
    else {

        my $mech = $self->mech;
        $mech->reset_headers;

        my $req_head = $req->headers;
        for my $field (@{ $self->request }) {
            my $value = $req_head->header($field) // next;
            $mech->add_header( $field => $value );
        }

        my $res  = $mech->get( $self->base . $path_query );
        my $body = encode("UTF-8", $mech->content);

        my $head = $res->headers;
        my $h = Plack::Util::headers([ 'X-Renderer' => __PACKAGE__ ]);
        for my $field (@{ $self->response }) {
            my $value = $head->header($field) // next;
            $value =~ tr/\n/ /;
            $h->set( $field => $value );
        }

        if ($res->code == HTTP_OK) {

            my $age;
            if (my $value = $head->header("Cache-Control")) {
                ($age) = $value =~ /(?:s\-)?max-age=([0-9]+)\b/;
            }

            $data = [ HTTP_OK, $h->headers, [$body] ];

            $cache->set( $path_query, $data, $age // $self->max_age );

            return $data;

        }
        else {

            return [ $res->code, $h->headers, [$body] ];

        }
    }

}

sub DESTROY {
    my $self = shift;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    $self->mech->close if $self->mech;
}

=head1 SEE ALSO

L<Plack>

L<WWW::Mechanize::Chrome>

Rendertron L<https://github.com/GoogleChrome/rendertron>

=cut

1;
