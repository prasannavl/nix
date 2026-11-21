<?php
define('ZPUSH_HOST', '@publicHostName@');
define('TIMEZONE', '@timeZone@');
define('BASE_PATH', dirname($_SERVER['SCRIPT_FILENAME']). '/');
define('USE_FULLEMAIL_FOR_LOGIN', true);
define('AUTODISCOVER_LOGIN_TYPE', AUTODISCOVER_LOGIN_EMAIL);
define('LOGBACKEND', 'filelog');
define('LOGFILEDIR', '@logDir@/');
define('LOGFILE', LOGFILEDIR . 'autodiscover.log');
define('LOGERRORFILE', LOGFILEDIR . 'autodiscover-error.log');
define('LOGLEVEL', LOGLEVEL_INFO);
define('LOGUSERLEVEL', LOGLEVEL);
$specialLogUsers = array();
define('LOG_SYSLOG_HOST', false);
define('LOG_SYSLOG_PORT', 514);
define('LOG_SYSLOG_PROGRAM', 'z-push-autodiscover');
define('LOG_SYSLOG_FACILITY', LOG_LOCAL0);
define('BACKEND_PROVIDER', 'BackendCombined');
