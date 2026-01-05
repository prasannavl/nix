{ config, pkgs, lib, ... }:
let
  userdata = import ./data/userdata.nix;
in
{
	home-manager.backupFileExtension = "hm.backup";
	home-manager.users.pvl = {
		home.packages = with pkgs; [
			atool
			gnomeExtensions.dash-to-panel
			gnomeExtensions.appindicator
			gnomeExtensions.caffeine
			gnomeExtensions.impatience
			gnomeExtensions.p7-borders
			gnomeExtensions.p7-commands
			gnomeExtensions.bluetooth-quick-connect
			gnomeExtensions.brightness-control-using-ddcutil
		];
		programs.bash.enable = true;

		programs.firefox = {
			enable = true;
			profiles = {
				default = {
					settings = {
						"general.smoothScroll" = false;
					};
				};
			};
  		};
		
		dconf = {
			enable = true;
			settings = {
				"org/gnome/shell" = {
					disable-user-extensions = false;
					enabled-extensions = with pkgs.gnomeExtensions; [
						dash-to-panel.extensionUuid
						appindicator.extensionUuid
						caffeine.extensionUuid
						impatience.extensionUuid
						p7-borders.extensionUuid
						p7-commands.extensionUuid
						bluetooth-quick-connect.extensionUuid
						brightness-control-using-ddcutil.extensionUuid
					];
					disabled-extensions = [];
					favorite-apps = [
						"google-chrome.desktop"
						"org.gnome.Terminal.desktop"
						"org.gnome.Nautilus.desktop"
						"org.gnome.TextEditor.desktop"
						"code.desktop"
						"dev.zed.Zed.desktop"
						"org.gnome.Calculator.desktop"
						"md.obsidian.Obsidian.desktop"
						"chrome-cadlkienfkclaiaibeoongdcgmdikeeg-Default.desktop"
						"antigravity.desktop"
					];
				};
				"org/gnome/desktop/wm/preferences" = {
					"button-layout" = ":minimize,maximize,close";
				};
				"org/gnome/desktop/interface" = {
					color-scheme = "prefer-dark";
				};
				"org/gnome/shell/keybindings" = {
					screenshot = [ "<Shift>Print" "<Shift><Super>c" ];
					screenshot-window = [ "<Alt>Print" "<Alt><Super>c" ];
					show-screenshot-ui = [ "Print" "<Super>c" ];
				};

				"org/gnome/shell/extensions/dash-to-panel" = {
					appicon-margin = 0;
					appicon-padding = 8;
					dot-style-focused = "DASHES";
					dot-style-unfocused = "DASHES";
					extension-version = 72;
					global-border-radius = 0;
					hide-overview-on-startup = true;
					hot-keys = true;
					show-favorites = true;
				};
				"org/gnome/shell/extensions/bluetooth-quick-connect" = {
					keep-menu-on-toggle = true;
					refresh-button-on = true;
					show-battery-value-on = true;
				};
			};
		};

		programs.git = {
			enable = true;
			settings = {
				user = {
					name = userdata.pvl.name;
					email = userdata.pvl.email;
					signingKey = userdata.pvl.sshKey;
				};
				commit.gpgSign = true;
				gpg.format = "ssh";
				core.autocrlf = "input";
				
				grep = {
					extendRegexp = true;
					lineNumber = true;
				};

				merge.conflictstyle = "diff3";
				push.autoSetupRemote = true;

				alias = {
					l = "log --oneline";
					log-full = "log --pretty=format:\"%h%x09%an%x09%ad%x09%s\"";
				};
			};

			lfs.enable = true;
			ignores = [
				".DS_Store"
				"result"
			];
		};

		home.file.".config/chrome-flags.conf".text = ''
			--disable-smooth-scrolling
			--enable-parallel-downloading
		'';

		# The state version is required and should stay at the version you
		# originally installed.
		home.stateVersion = "25.11";
  };
}

