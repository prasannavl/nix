{pkgs}: let
  recipients = import ../../../../data/secrets;
  validRecipient = recipient:
    builtins.isAttrs recipient
    && recipient ? publicKeys
    && builtins.isList recipient.publicKeys
    && recipient.publicKeys != []
    && builtins.all builtins.isString recipient.publicKeys;
in {
  pvl-secret-recipients = assert recipients != {} || throw "Pvl secret recipients must not be empty";
  assert builtins.all validRecipient (builtins.attrValues recipients) || throw "Pvl secret recipients must declare non-empty public-key lists";
    pkgs.runCommand "pvl-secret-recipients-test" {} ''
      touch "$out"
    '';
}
