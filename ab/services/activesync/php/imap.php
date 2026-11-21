<?php
define('IMAP_SERVER', '@server@');
define('IMAP_PORT', @imapsPort@);
define('IMAP_OPTIONS', '@options@');
define('IMAP_AUTOSEEN_ON_DELETE', false);
define('IMAP_FOLDER_CONFIGURED', true);
define('IMAP_FOLDER_PREFIX', "");
define('IMAP_FOLDER_PREFIX_IN_INBOX', false);
define('IMAP_FOLDER_INBOX', 'INBOX');
define('IMAP_FOLDER_SENT', '@imapFolderSent@');
define('IMAP_FOLDER_DRAFT', '@imapFolderDraft@');
define('IMAP_FOLDER_TRASH', '@imapFolderTrash@');
define('IMAP_FOLDER_SPAM', '@imapFolderSpam@');
define('IMAP_FOLDER_ARCHIVE', '@imapFolderArchive@');
define('IMAP_INLINE_FORWARD', true);
define('IMAP_EXCLUDED_FOLDERS', "");
define('IMAP_DEFAULTFROM', '@imapDefaultFrom@');
define('IMAP_FROM_SQL_DSN', "");
define('IMAP_FROM_SQL_USER', "");
define('IMAP_FROM_SQL_PASSWORD', "");
define('IMAP_FROM_SQL_OPTIONS', serialize(array(PDO::ATTR_PERSISTENT => true)));
define('IMAP_FROM_SQL_QUERY', "select first_name, last_name, mail_address from users where mail_address = '#username@#domain'");
define('IMAP_FROM_SQL_FIELDS', serialize(array('first_name', 'last_name', 'mail_address')));
define('IMAP_FROM_SQL_EMAIL', '#mail_address');
define('IMAP_FROM_SQL_FROM', '#first_name #last_name <#mail_address>');
define('IMAP_FROM_SQL_FULLNAME', '#first_name #last_name');
define('IMAP_FROM_LDAP_SERVER_URI', @imapFromLdapServerUri@);
define('IMAP_FROM_LDAP_USER', @imapFromLdapBindDn@);
define('IMAP_FROM_LDAP_PASSWORD', @imapFromLdapPassword@);
define('IMAP_FROM_LDAP_BASE', @imapFromLdapBase@);
define('IMAP_FROM_LDAP_QUERY', @imapFromLdapQuery@);
define('IMAP_FROM_LDAP_FIELDS', serialize(array(@imapFromLdapFields@)));
define('IMAP_FROM_LDAP_EMAIL', @imapFromLdapEmail@);
define('IMAP_FROM_LDAP_FROM', @imapFromLdapFrom@);
define('IMAP_FROM_LDAP_FULLNAME', @imapFromLdapFullName@);
define('IMAP_SMTP_METHOD', 'smtp');
global $imap_smtp_params;
$imap_smtp_params = array(
  'host' => '@smtpHost@',
  'port' => @submissionsPort@,
  'auth' => true,
  'username' => 'imap_username',
  'password' => 'imap_password',
  'localhost' => '@activesyncHostName@',
  'timeout' => 30,
  'socket_options' => array(
    'ssl' => array(
      'cafile' => '@caBundlePath@',
      'peer_name' => '@smtpPeerName@',
      'SNI_enabled' => true,
      'SNI_server_name' => '@smtpPeerName@',
    ),
  ),
  'verify_peer' => @smtpVerifyPeer@,
  'verify_peer_name' => @smtpVerifyPeerName@,
  'allow_self_signed' => @smtpAllowSelfSigned@,
);
define('MAIL_MIMEPART_CRLF', "\r\n");
define('SYSTEM_MIME_TYPES_MAPPING', '@mimeTypesPath@');
define('IMAP_MEETING_USE_CALDAV', false);
define('IMAP_MEETING_RESPONSE_USE_CALDAV', true);
define('IMAP_SENDMAIL_SUPPRESS_CALENDAR_OBJECTS', true);
define('IMAP_SEARCH_CHARSET', 'UTF-8');
