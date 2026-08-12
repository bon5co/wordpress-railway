<?php
/**
 * Plugin Name: Railway login throttle
 * Description: Rate-limits failed logins per client address. WordPress core ships
 *              no throttle of any kind: 40 wrong passwords against a stock
 *              instance all returned HTTP 200, 20 of them in 1.455 seconds.
 * Author: bon5co
 *
 * The key is REMOTE_ADDR, which is only the real visitor because the image adds
 * Railway's edge range to mod_remoteip's trusted proxies. Without that fix this
 * would throttle the edge, i.e. every visitor at once and no attacker in
 * particular.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

function railway_login_client_ip() {
	$ip = isset( $_SERVER['REMOTE_ADDR'] ) ? (string) $_SERVER['REMOTE_ADDR'] : '';
	return filter_var( $ip, FILTER_VALIDATE_IP ) ? $ip : 'unknown';
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
