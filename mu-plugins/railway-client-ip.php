<?php
/**
 * Plugin Name: Railway client IP + login throttle
 * Description: Restores the real visitor address and rate-limits failed logins
 *              per client. WordPress core ships no throttle of any kind: 40
 *              wrong passwords against a stock instance all returned HTTP 200,
 *              20 of them in 1.455 seconds.
 * Author: bon5co
 *
 * Measured on a live Railway deploy, two consecutive requests from one client:
 *
 *     remote_addr=152.233.33.163   xff=106.73.62.0
 *     remote_addr=152.233.33.161   xff=106.73.62.0
 *
 * REMOTE_ADDR is Railway's edge and it ROTATES per request; X-Forwarded-For is
 * the visitor and it is stable. Every WordPress feature keyed on REMOTE_ADDR --
 * the IP stored with each comment, every security plugin's blocklist, every
 * rate limit -- is therefore recording a proxy hop that the next request no
 * longer comes from. Apache's mod_remoteip cannot fix it either, because the
 * edge address is a public one that changes, so there is no proxy range to
 * trust; the header is the only stable source.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * The FIRST address of X-Forwarded-For, not the whole header and not
 * REMOTE_ADDR.
 *
 * Railway's edge sends "<client>, <edge>" and the edge hop rotates per request,
 * so a key built from the whole header (or from the peer address, which is
 * always the edge) changes every few requests and no counter ever reaches its
 * limit. The first address is written by Railway's edge, which replaces any
 * inbound X-Forwarded-For, so a client cannot forge it.
 */
function railway_login_client_ip() {
	if ( ! empty( $_SERVER['HTTP_X_FORWARDED_FOR'] ) ) {
		$first = trim( strtok( (string) $_SERVER['HTTP_X_FORWARDED_FOR'], ',' ) );
		if ( filter_var( $first, FILTER_VALIDATE_IP ) ) {
			return $first;
		}
	}

	$ip = isset( $_SERVER['REMOTE_ADDR'] ) ? (string) $_SERVER['REMOTE_ADDR'] : '';
	return filter_var( $ip, FILTER_VALIDATE_IP ) ? $ip : 'unknown';
}

/**
 * Hand the real address to everything that reads REMOTE_ADDR -- comment
 * records, security plugins, anything counting requests per visitor -- while
 * keeping the edge hop available for debugging.
 */
if ( ! empty( $_SERVER['HTTP_X_FORWARDED_FOR'] ) ) {
	$railway_client_ip = railway_login_client_ip();
	if ( 'unknown' !== $railway_client_ip ) {
		$_SERVER['RAILWAY_EDGE_ADDR'] = isset( $_SERVER['REMOTE_ADDR'] ) ? $_SERVER['REMOTE_ADDR'] : '';
		$_SERVER['REMOTE_ADDR']       = $railway_client_ip;
	}
	unset( $railway_client_ip );
}

function railway_login_limits() {
	$max = (int) getenv( 'WORDPRESS_LOGIN_MAX_ATTEMPTS' );
	$win = (int) getenv( 'WORDPRESS_LOGIN_WINDOW' );

	return array(
		'max'    => $max > 0 ? $max : 10,
		'window' => $win > 0 ? $win : 900,
	);
}

function railway_login_key() {
	return 'railway_login_fail_' . md5( railway_login_client_ip() );
}

/**
 * Runs before credentials are checked, so a blocked client never reaches the
 * password hashing path at all.
 */
function railway_login_gate( $user ) {
	if ( empty( $_POST['log'] ) && empty( $_POST['pwd'] ) ) {
		return $user;
	}

	$limits = railway_login_limits();
	$fails  = (int) get_transient( railway_login_key() );

	if ( $fails >= $limits['max'] ) {
		status_header( 429 );
		nocache_headers();
		header( 'Retry-After: ' . $limits['window'] );
		wp_die(
			esc_html__( 'Too many failed login attempts from this address. Try again later.', 'railway' ),
			esc_html__( 'Too many attempts', 'railway' ),
			array( 'response' => 429 )
		);
	}

	return $user;
}
add_filter( 'authenticate', 'railway_login_gate', 1 );

function railway_login_record_failure() {
	$limits = railway_login_limits();
	$key    = railway_login_key();
	$fails  = (int) get_transient( $key );

	set_transient( $key, $fails + 1, $limits['window'] );
}
add_action( 'wp_login_failed', 'railway_login_record_failure' );

function railway_login_clear_failures() {
	delete_transient( railway_login_key() );
}
add_action( 'wp_login', 'railway_login_clear_failures' );

/**
 * XML-RPC accepts credential guesses in batches through system.multicall, which
 * makes the throttle above much less useful while it is reachable. Apache
 * denies /xmlrpc.php as well; this closes the internal callers too.
 */
if ( '1' !== (string) getenv( 'WORDPRESS_ENABLE_XMLRPC' ) ) {
	add_filter( 'xmlrpc_enabled', '__return_false' );
}
