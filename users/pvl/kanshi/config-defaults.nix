{
  lib,
  outputs,
}: let
  renderOutput = output: ''
    output "${output.name}" mode ${output.mode} scale ${output.scale} scale_filter ${output.scaleFilter} subpixel ${output.subpixel} transform ${output.transform}${lib.optionalString output.vrr " adaptive_sync on"}
  '';
in
  lib.concatMapStringsSep "\n" renderOutput outputs.all
