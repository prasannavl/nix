{
  inputs,
  system,
  ...
}: {
  vulkan = inputs.vocalinux.packages.${system}.default;
}
