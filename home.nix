{ config, pkgs, lib, ... }:
let
  userdata = import ./data/userdata.nix;
in
{
	home-manager.backupFileExtension = "hm.backup";
	home-manager.users.pvl = {
		home.packages = with pkgs; [
			atool
			gnomeExtensions.appindicator
			gnomeExtensions.auto-move-windows
			gnomeExtensions.bluetooth-quick-connect
			gnomeExtensions.brightness-control-using-ddcutil
			gnomeExtensions.caffeine
			gnomeExtensions.clipboard-indicator
			gnomeExtensions.dash-to-panel
			gnomeExtensions.gsconnect
			gnomeExtensions.impatience
			gnomeExtensions.p7-borders
			gnomeExtensions.p7-commands
			gnomeExtensions.native-window-placement
			gnomeExtensions.windownavigator
			gnomeExtensions.workspace-indicator
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
						appindicator.extensionUuid
						bluetooth-quick-connect.extensionUuid
						brightness-control-using-ddcutil.extensionUuid
						caffeine.extensionUuid
						clipboard-indicator.extensionUuid
						dash-to-panel.extensionUuid
						impatience.extensionUuid
						p7-borders.extensionUuid
						p7-commands.extensionUuid
						windownavigator.extensionUuid
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
				"org/gnome/desktop/sound" = {
					allow-volume-above-100-percent = true;
				};
				"org/gnome/desktop/a11y" = {
					always-show-universal-access-status = true;
				};
				"org/gnome/desktop/remote-desktop/rdp" = {
					enable = true;
				};

				"org/gnome/desktop/interface" = {
					# accent-color = "blue";
					clock-format = "12h";
					clock-show-seconds = true;
					clock-show-weekday = true;
					# color-scheme = "prefer-dark";
					# document-font-name = "Cantarell 11";
					# enable-animations = true;
					# enable-hot-corners = true;
					# font-name = "Cantarell 11";
					# gtk-theme = "Adwaita";
					# icon-theme = "Adwaita";
					# monospace-font-name = "Monospace 12";
					# overlay-scrolling = true;
					show-battery-percentage = true;
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
				"org/gnome/shell/extensions/display-brightness-ddcutil" = {
					button-location = 1;
					ddcutil-binary-path = "${pkgs.ddcutil}/bin/ddcutil";
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
		'';

		# The state version is required and should stay at the version you
		# originally installed.
		home.stateVersion = "25.11";
  };
}

