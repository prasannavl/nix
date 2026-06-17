{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.activesync;
  types = lib.types;
  phpBool = value:
    if value
    then "true"
    else "false";
  phpSingleQuoted = value: "'${lib.replaceStrings ["\\" "'"] ["\\\\" "\\'"] value}'";
  phpArrayItems = values: lib.concatStringsSep ", " (map phpSingleQuoted values);
  imapSenderIdentity = cfg.imap.senderIdentity;
  imapSenderIdentityLdap = imapSenderIdentity.ldap;
  imapDefaultFrom =
    if imapSenderIdentity.mode == "none"
    then ""
    else imapSenderIdentity.mode;
  imapFromLdapPassword =
    if imapSenderIdentity.mode == "ldap"
    then "trim(file_get_contents(${phpSingleQuoted imapSenderIdentityLdap.bindPasswordFile}))"
    else "\"\"";
  zpushPhpDefault = pkgs.php.withExtensions (extensions:
    lib.unique (extensions.enabled
      ++ (with extensions.all; [
        ctype
        curl
        fileinfo
        iconv
        imap
        ldap
        mbstring
        openssl
        pdo
        posix
        session
        simplexml
        sockets
        sysvmsg
        sysvsem
        sysvshm
        xmlreader
        xmlwriter
        xsl
        zlib
      ])));
  zpushConfig = pkgs.replaceVars ./php/config.php {
    stateDir = cfg.stateDir;
    logDir = cfg.logDir;
    activeSyncPingMaxLifetimeSec = toString cfg.pingMaxLifetimeSec;
    inherit (cfg) timeZone;
  };
  zpushAutodiscoverConfig = pkgs.replaceVars ./php/autodiscover.php {
    inherit (cfg) publicHostName timeZone;
    logDir = cfg.logDir;
  };
  zpushCombinedConfig = ./php/combined.php;
  zpushImapConfig = pkgs.replaceVars ./php/imap.php {
    inherit (cfg.imap) server options;
    imapsPort = toString cfg.imap.port;
    submissionsPort = toString cfg.smtp.port;
    smtpHost = cfg.smtp.host;
    smtpPeerName = cfg.smtp.peerName;
    smtpVerifyPeer = phpBool cfg.smtp.verifyPeer;
    smtpVerifyPeerName = phpBool cfg.smtp.verifyPeerName;
    smtpAllowSelfSigned = phpBool cfg.smtp.allowSelfSigned;
    caBundlePath =
      if cfg.smtp.caBundlePath == null
      then ""
      else cfg.smtp.caBundlePath;
    activesyncHostName = cfg.publicHostName;
    imapFolderSent = cfg.imap.folders.sent;
    imapFolderDraft = cfg.imap.folders.draft;
    imapFolderTrash = cfg.imap.folders.trash;
    imapFolderSpam = cfg.imap.folders.spam;
    imapFolderArchive = cfg.imap.folders.archive;
    mimeTypesPath = cfg.mimeTypesPath;
    inherit imapDefaultFrom imapFromLdapPassword;
    imapFromLdapServerUri = phpSingleQuoted imapSenderIdentityLdap.serverUri;
    imapFromLdapBindDn = phpSingleQuoted imapSenderIdentityLdap.bindDn;
    imapFromLdapBase = phpSingleQuoted imapSenderIdentityLdap.baseDn;
    imapFromLdapQuery = phpSingleQuoted imapSenderIdentityLdap.query;
    imapFromLdapFields = phpArrayItems imapSenderIdentityLdap.fields;
    imapFromLdapEmail = phpSingleQuoted imapSenderIdentityLdap.email;
    imapFromLdapFrom = phpSingleQuoted imapSenderIdentityLdap.from;
    imapFromLdapFullName = phpSingleQuoted imapSenderIdentityLdap.fullName;
  };
  zpushCalDavConfig = pkgs.replaceVars ./php/caldav.php {
    davPort = toString cfg.dav.port;
    inherit (cfg.dav) protocol server;
    inherit (cfg.dav.caldav) path personal;
    supportsSync = phpBool cfg.dav.caldav.supportsSync;
  };
  zpushCardDavConfig = pkgs.replaceVars ./php/carddav.php {
    davPort = toString cfg.dav.port;
    inherit (cfg.dav) protocol server;
    inherit (cfg.dav.carddav) path defaultPath contactsFolderName vcardExtension;
    supportsSync = phpBool cfg.dav.carddav.supportsSync;
    supportsFnSearch = phpBool cfg.dav.carddav.supportsFnSearch;
  };
  zpushRoot = pkgs.runCommand cfg.rootPackageName {} ''
    cp -R ${cfg.package}/share/z-push $out
    chmod -R u+w $out
    cp ${zpushConfig} $out/config.php
    cp ${zpushAutodiscoverConfig} $out/autodiscover/config.php
    cp ${zpushCombinedConfig} $out/backend/combined/config.php
    cp ${zpushImapConfig} $out/backend/imap/config.php
    cp ${zpushCalDavConfig} $out/backend/caldav/config.php
    cp ${zpushCardDavConfig} $out/backend/carddav/config.php
  '';
  zpushDocumentRoot = cfg.documentRoot;
  fastcgiBase = ''
    include /etc/nginx/fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $request_filename;
    fastcgi_param DOCUMENT_ROOT ${zpushDocumentRoot};
    fastcgi_param HTTP_PROXY "";
    fastcgi_read_timeout ${cfg.nginx.timeout};
    fastcgi_send_timeout ${cfg.nginx.timeout};
    fastcgi_request_buffering off;
    fastcgi_pass ${cfg.nginx.fastcgiPass};
  '';
  originServerConfig = ''
    server {
        listen 80;
        server_name ${lib.concatStringsSep " " cfg.nginx.serverNames};

        location = /healthz {
            return 204;
        }

        location = /Microsoft-Server-ActiveSync {
            alias ${zpushDocumentRoot}/index.php;
            client_max_body_size ${cfg.clientBodySizes.activeSync};
            client_body_buffer_size 128k;
            ${fastcgiBase}
        }

        location = /AutoDiscover/AutoDiscover.xml {
            alias ${zpushDocumentRoot}/autodiscover/autodiscover.php;
            client_max_body_size ${cfg.clientBodySizes.autodiscover};
            ${fastcgiBase}
        }

        location = /Autodiscover/Autodiscover.xml {
            alias ${zpushDocumentRoot}/autodiscover/autodiscover.php;
            client_max_body_size ${cfg.clientBodySizes.autodiscover};
            ${fastcgiBase}
        }

        location = /autodiscover/autodiscover.xml {
            alias ${zpushDocumentRoot}/autodiscover/autodiscover.php;
            client_max_body_size ${cfg.clientBodySizes.autodiscover};
            ${fastcgiBase}
        }
    }
  '';
  phpIncludePath = builtins.concatStringsSep ":" [
    "."
    zpushDocumentRoot
    "${zpushDocumentRoot}/backend/imap"
    "${cfg.awlPackage}/share/awl/inc"
  ];
  openBasedir = builtins.concatStringsSep ":" (
    [
      zpushDocumentRoot
      "${zpushRoot}"
      "${cfg.awlPackage}/share/awl/inc"
      cfg.dataDir
      "${pkgs.mailcap}/etc"
    ]
    ++ lib.optionals (cfg.smtp.caBundlePath != null) [cfg.smtp.caBundlePath]
    ++ lib.optionals (imapSenderIdentity.mode == "ldap") [imapSenderIdentityLdap.bindPasswordFile]
    ++ cfg.extraOpenBasedir
    ++ ["/tmp"]
  );
in {
  options.services.activesync = {
    enable = lib.mkEnableOption "Z-Push Exchange ActiveSync bridge";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.z-push;
      description = "Z-Push package to serve.";
    };

    awlPackage = lib.mkOption {
      type = types.package;
      default = pkgs.awl;
      description = "AWL PHP support library package used by Z-Push CalDAV code.";
    };

    phpPackage = lib.mkOption {
      type = types.package;
      default = zpushPhpDefault;
      description = "PHP package with the extensions required by Z-Push.";
    };

    rootPackageName = lib.mkOption {
      type = types.str;
      default = "activesync-z-push-root";
      description = "Name for the generated Z-Push root derivation.";
    };

    documentRoot = lib.mkOption {
      type = types.str;
      default = "${cfg.dataDir}/www";
      description = "Stable host path exposed as the Z-Push FastCGI document root.";
    };

    user = lib.mkOption {
      type = types.str;
      default = "zpush";
      description = "System user running PHP-FPM for ActiveSync.";
    };

    group = lib.mkOption {
      type = types.str;
      default = "zpush";
      description = "System group running PHP-FPM for ActiveSync.";
    };

    dataDir = lib.mkOption {
      type = types.str;
      default = "/var/lib/activesync";
      description = "Persistent base directory for Z-Push state and logs.";
    };

    stateDir = lib.mkOption {
      type = types.str;
      default = "${cfg.dataDir}/state";
      description = "Persistent Z-Push state directory.";
    };

    logDir = lib.mkOption {
      type = types.str;
      default = "${cfg.dataDir}/log";
      description = "Persistent Z-Push log directory.";
    };

    publicHostName = lib.mkOption {
      type = types.str;
      description = "Public ActiveSync hostname advertised by autodiscover.";
    };

    phpFpmPoolName = lib.mkOption {
      type = types.str;
      default = "activesync";
      description = "PHP-FPM pool name for ActiveSync.";
    };

    phpFpm = {
      listenAddress = lib.mkOption {
        type = types.str;
        description = "Address PHP-FPM should bind for FastCGI requests.";
      };

      port = lib.mkOption {
        type = types.port;
        description = "Host-local FastCGI TCP port for PHP-FPM.";
      };

      allowedCidrs = lib.mkOption {
        type = types.listOf types.str;
        default = [];
        description = "CIDR ranges allowed to reach the PHP-FPM FastCGI port.";
      };
    };

    timeZone = lib.mkOption {
      type = types.str;
      default =
        if config.time.timeZone != null
        then config.time.timeZone
        else "UTC";
      description = "Default PHP/Z-Push timezone for parsing, logging, and fallback conversions.";
    };

    pingMaxLifetimeSec = lib.mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Maximum ActiveSync Ping long-poll lifetime in seconds.";
    };

    processTimeoutSec = lib.mkOption {
      type = types.ints.positive;
      default = 900;
      description = "PHP-FPM request timeout for long-running ActiveSync requests.";
    };

    clientBodySizes = {
      activeSync = lib.mkOption {
        type = types.str;
        default = "20m";
        description = "Maximum request body size for the ActiveSync endpoint.";
      };

      autodiscover = lib.mkOption {
        type = types.str;
        default = "2m";
        description = "Maximum request body size for autodiscover endpoints.";
      };
    };

    mimeTypesPath = lib.mkOption {
      type = types.str;
      default = "${pkgs.mailcap}/etc/mime.types";
      description = "MIME type mapping file used by the Z-Push IMAP backend.";
    };

    extraOpenBasedir = lib.mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra PHP open_basedir entries for the ActiveSync pool.";
    };

    imap = {
      server = lib.mkOption {
        type = types.str;
        description = "IMAP server hostname or address used by Z-Push.";
      };

      port = lib.mkOption {
        type = types.port;
        description = "IMAP server port used by Z-Push.";
      };

      options = lib.mkOption {
        type = types.str;
        default = "/ssl/novalidate-cert/norsh";
        description = "PHP IMAP connection option string.";
      };

      senderIdentity = {
        mode = lib.mkOption {
          type = types.enum ["none" "username" "domain" "ldap"];
          default = "username";
          description = "How Z-Push should derive outgoing IMAP From headers for EAS SendMail.";
        };

        ldap = {
          serverUri = lib.mkOption {
            type = types.str;
            default = "";
            description = "LDAP URI used when deriving outgoing IMAP From headers from LDAP.";
          };

          bindDn = lib.mkOption {
            type = types.str;
            default = "";
            description = "LDAP bind DN used for sender identity lookup.";
          };

          bindPasswordFile = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Runtime file containing the LDAP bind secret for sender identity lookup.";
          };

          baseDn = lib.mkOption {
            type = types.str;
            default = "";
            description = "LDAP base DN used for sender identity lookup.";
          };

          query = lib.mkOption {
            type = types.str;
            default = "(mail=#username)";
            description = "LDAP filter used for sender identity lookup. Z-Push substitutes #username and #domain.";
          };

          fields = lib.mkOption {
            type = types.listOf types.str;
            default = ["displayname" "mail"];
            description = "LDAP attributes Z-Push should fetch for sender identity lookup.";
          };

          email = lib.mkOption {
            type = types.str;
            default = "#mail";
            description = "Template for the sender email address from LDAP fields.";
          };

          from = lib.mkOption {
            type = types.str;
            default = "#displayname <#mail>";
            description = "Template for the RFC 5322 From header from LDAP fields.";
          };

          fullName = lib.mkOption {
            type = types.str;
            default = "#displayname";
            description = "Template for the sender full name from LDAP fields.";
          };

          caCertFile = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional CA bundle exposed to LDAP TLS clients in the PHP-FPM pool.";
          };
        };
      };

      folders = {
        sent = lib.mkOption {
          type = types.str;
          default = "Sent";
          description = "IMAP Sent folder name.";
        };
        draft = lib.mkOption {
          type = types.str;
          default = "Drafts";
          description = "IMAP Drafts folder name.";
        };
        trash = lib.mkOption {
          type = types.str;
          default = "Trash";
          description = "IMAP Trash folder name.";
        };
        spam = lib.mkOption {
          type = types.str;
          default = "Junk";
          description = "IMAP Spam/Junk folder name.";
        };
        archive = lib.mkOption {
          type = types.str;
          default = "Archive";
          description = "IMAP Archive folder name.";
        };
      };
    };

    smtp = {
      host = lib.mkOption {
        type = types.str;
        description = "SMTP host string for Z-Push mail submission.";
      };

      port = lib.mkOption {
        type = types.port;
        description = "SMTP submission port.";
      };

      peerName = lib.mkOption {
        type = types.str;
        description = "TLS peer/SNI name expected from the SMTP endpoint.";
      };

      caBundlePath = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CA bundle path used to verify the SMTP endpoint.";
      };

      verifyPeer = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether SMTP TLS should verify the peer certificate.";
      };

      verifyPeerName = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether SMTP TLS should verify the peer name.";
      };

      allowSelfSigned = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Whether SMTP TLS should allow self-signed certificates.";
      };
    };

    dav = {
      protocol = lib.mkOption {
        type = types.enum ["http" "https"];
        description = "Protocol for CalDAV/CardDAV backend requests.";
      };

      server = lib.mkOption {
        type = types.str;
        description = "CalDAV/CardDAV server hostname or address.";
      };

      port = lib.mkOption {
        type = types.port;
        description = "CalDAV/CardDAV server port.";
      };

      caldav = {
        path = lib.mkOption {
          type = types.str;
          default = "/dav/cal/%u/";
          description = "CalDAV account path template.";
        };

        personal = lib.mkOption {
          type = types.str;
          default = "default";
          description = "Default personal CalDAV collection.";
        };

        supportsSync = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Whether the CalDAV backend supports sync-collection.";
        };
      };

      carddav = {
        path = lib.mkOption {
          type = types.str;
          default = "/dav/card/%u/";
          description = "CardDAV account path template.";
        };

        defaultPath = lib.mkOption {
          type = types.str;
          default = "/dav/card/%u/default/";
          description = "Default CardDAV address book path template.";
        };

        contactsFolderName = lib.mkOption {
          type = types.str;
          default = "Contacts";
          description = "ActiveSync display name for the default contacts folder.";
        };

        supportsSync = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Whether the CardDAV backend supports sync-collection.";
        };

        supportsFnSearch = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Whether the CardDAV backend supports FN text-match searches.";
        };

        vcardExtension = lib.mkOption {
          type = types.str;
          default = "";
          description = "Suffix appended by Z-Push to vCard object URLs.";
        };
      };
    };

    nginx = {
      serverNames = lib.mkOption {
        type = types.nonEmptyListOf types.str;
        default = [cfg.publicHostName];
        defaultText = lib.literalExpression "[ config.services.activesync.publicHostName ]";
        description = "Hostnames served by the rendered ActiveSync nginx origin vhost.";
      };

      fastcgiPass = lib.mkOption {
        type = types.str;
        description = "Nginx fastcgi_pass target for the ActiveSync PHP-FPM pool.";
      };

      timeout = lib.mkOption {
        type = types.str;
        default = "15m";
        description = "Nginx FastCGI read/send timeout for ActiveSync requests.";
      };

      serverConfig = lib.mkOption {
        type = types.lines;
        readOnly = true;
        description = "Rendered nginx server block for an ActiveSync FastCGI origin adapter.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          imapSenderIdentity.mode
          != "ldap"
          || (
            imapSenderIdentityLdap.serverUri
            != ""
            && imapSenderIdentityLdap.bindDn != ""
            && imapSenderIdentityLdap.bindPasswordFile != null
            && imapSenderIdentityLdap.baseDn != ""
            && imapSenderIdentityLdap.fields != []
          );
        message = "services.activesync.imap.senderIdentity.ldap must set serverUri, bindDn, bindPasswordFile, baseDn, and fields when mode is ldap.";
      }
    ];

    users.groups.${cfg.group} = {};
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.logDir} 0750 ${cfg.user} ${cfg.group} -"
      "L+ ${zpushDocumentRoot} - ${cfg.user} ${cfg.group} - ${zpushRoot}"
    ];

    networking.firewall.extraInputRules = lib.mkIf (cfg.phpFpm.allowedCidrs != []) ''
      ip saddr { ${lib.concatStringsSep ", " cfg.phpFpm.allowedCidrs} } tcp dport ${toString cfg.phpFpm.port} accept
    '';

    services.phpfpm.pools.${cfg.phpFpmPoolName} = {
      user = cfg.user;
      group = cfg.group;
      phpPackage = cfg.phpPackage;
      settings =
        {
          "listen" = "${cfg.phpFpm.listenAddress}:${toString cfg.phpFpm.port}";
          "pm" = "dynamic";
          "pm.max_children" = 16;
          "pm.start_servers" = 2;
          "pm.min_spare_servers" = 1;
          "pm.max_spare_servers" = 4;
          "pm.max_requests" = 500;
          "catch_workers_output" = true;
          "php_admin_value[include_path]" = phpIncludePath;
          "php_admin_value[open_basedir]" = openBasedir;
          "php_admin_value[error_reporting]" = "E_ALL & ~E_DEPRECATED & ~E_STRICT";
          "php_admin_flag[display_errors]" = "off";
          "php_admin_flag[log_errors]" = "on";
          "php_admin_value[post_max_size]" = "20M";
          "php_admin_value[upload_max_filesize]" = "20M";
          "php_admin_value[max_execution_time]" = toString cfg.processTimeoutSec;
          "php_admin_value[max_input_time]" = toString cfg.processTimeoutSec;
          "php_admin_value[memory_limit]" = "256M";
        }
        // lib.optionalAttrs (imapSenderIdentity.mode == "ldap" && imapSenderIdentityLdap.caCertFile != null) {
          "env[LDAPTLS_CACERT]" = imapSenderIdentityLdap.caCertFile;
        };
    };

    services.activesync.nginx.serverConfig = originServerConfig;
  };
}
