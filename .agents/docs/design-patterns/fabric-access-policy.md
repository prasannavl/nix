# Grouped fabric access

- A rule grants its ports from every source selector to every destination
  selector. Group equal permissions, never unrelated source/destination pairs.
- Stack declarations accept a selector or nonempty list for `from` and `to`.
  Sources belong to the declaring stack; destinations name their `stack`.
- Either side accepts `endpointGroup` or `endpointGroups`, never both. Omission
  selects that stack's active group. Optional `role` narrows a fabric to one
  host.

```nix
access.ci-management = {
  from.role = "ci";
  to = [
    {stack = "production"; endpointGroups = ["primary" "standby"];}
    {stack = "development";}
  ];
  tcp = [22];
};
```

- The independent physical projection uses `fabric`/`fabrics` and `endpoint`
  selectors, with the same singleton/list and Cartesian semantics.
- Shared `lib/flake/access-selectors.nix` rejects empty lists, conflicting
  singular/plural fields, repeated selectors and unknown fields. Contracts also
  validate referenced fabrics/endpoints and ports before rendering.
- Expanded contract records remain concrete source/destination/family/port
  flows. Legacy IDs remain compatible; grouped IDs derive from endpoint
  identities, never list positions. Reordering a declaration does not change its
  permissions.
- Regression tests compare complete flow sets, not just declaration counts.

## Enforcement boundary

Routed admission is not host-service admission. Same-fabric traffic may bypass
router forwarding hooks; enforce a host's restricted listener on that host too.
An early input guard can reject unauthorized traffic before ordinary firewall
trusted-interface or established-flow accepts. Add narrow positive admission to
that host's normal firewall separately. Keep unrelated services unaffected.

Cache consumer metadata selects substituters; it is not network authorization.
