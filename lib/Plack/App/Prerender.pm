package Plack::App::Prerender;

use v5.10;
use strict;
use warnings;

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

sub prepare_app {
    my ($self) = @_;

    unless ($self->mech) {

        my $mech = WWW::Mechanize::Chrome->new(
            headless         => 1,
            separate_session => 1,
            launch_arg => [qw/ --start-maximized /],
        );

        $self->mech($mech);

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

1;
