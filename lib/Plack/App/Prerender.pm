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
use Plack::Util::Accessor qw/ mech rewrite cache max_age request response /;
use Ref::Util qw/ is_coderef is_plain_arrayref /;
use Time::Seconds qw/ ONE_HOUR /;
use WWW::Mechanize::Chrome;

# RECOMMEND PREREQ: CHI
# RECOMMEND PREREQ: Log::Log4perl
# RECOMMEND PREREQ: Ref::Util::XS

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
      rewrite => "http://www.example.com",
      cache   => $cache,
  )->to_app;

=head1 DESCRIPTION

This is a PSGI application that acts as a simple prerendering proxy
for websites using Chrone.

This only supports GET requests, as this is intended as a proxy for
search engines that do not support AJAX-generated content.

=attr mech

A L<WWW::Mechanize::Chrome> object. If omitted, a headless instance of
Chrome will be launched.

If you want to specify alternative options, you chould create your own
instance of WWW::Mechanize::Chrome and pass it to the constructor.

=attr rewrite

This can either be a base URL prefix string, or a code reference that
takes the PSGI C<REQUEST_URI> and environment hash as arguments, and
returns a full URL to pass to L</mech>.

If the code reference returns C<undef>, then the request will abort
with an HTTP 400.

If the code reference returns an array reference, then it assumes the
request is a Plack response and simply returns it.

This can be used for simple request validation.  For example,

  use Robots::Validate;

  sub validator {
    my ($path, $env) = @_;

    state $rv = Robots::Validate->new();

    unless ( $rv->validate(
      $env->{REMOTE_ADDR}, { agent => $env->{USER_AGENT} } )) {
        return [ 403, [], [] ];
    }

    ...
  }

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

This only does the bare minimum necessary for proxying requests. You
may need additional middleware for reverse proxies, logging, or
security filtering.

=cut

sub prepare_app {
    my ($self) = @_;

    unless ($self->mech) {

        my $mech = WWW::Mechanize::Chrome->new(
            headless         => 1,
            separate_session => 1,
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
        return [ HTTP_METHOD_NOT_ALLOWED, [], [] ];
    }

    my $path_query = $env->{REQUEST_URI};

    my $base = $self->rewrite;
    my $url  = is_coderef($base)
        ? $base->($path_query, $env)
        : $base . $path_query;

    $url //= [ HTTP_BAD_REQUEST, [], [] ];
    return $url if (is_plain_arrayref($url));

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

        my $res  = $mech->get( $url );
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
