"""Pure selection of original Cargo unpack prerequisites for ordinary Nix CLI builds.

The caller authenticates the complete original pending/native union and graph.
This module neither executes commands nor reads or writes filesystem state.
"""
import re


_STORE = re.compile(r'/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+\Z')


def _check(ok, message):
    if not ok:
        raise ValueError(message)


def _path(value):
    _check(isinstance(value, str) and _STORE.fullmatch(value), 'canonical store path')
    return value


def _output(node, output):
    info = node['outputs'][output]
    path = _path(node['env'][output])
    if 'path' in info:
        _check(path == '/nix/store/' + info['path'], 'canonical graph output mismatch')
    return path


def select_batches(pending, graph, valid):
    """Return sorted batches of at most 16 exact pending cargo-package-* rows.

    Cached dependencies are frontier leaves, not permission to build descendants.
    All selected immediate outputs, input sources and descriptors must be valid.
    """
    seen, selected = set(), []
    for row in pending:
        _check(set(row) == {'derivationPath', 'output', 'storePath', 'name'}, 'pending schema')
        drv, path = _path(row['derivationPath']), _path(row['storePath'])
        _check(drv.endswith('.drv') and drv not in seen, 'duplicate/non-derivation pending row')
        seen.add(drv)
        node = graph[drv.removeprefix('/nix/store/')]
        _check(row['output'] == 'out' and node['name'] == row['name']
               and node['outputs'] == {'out': {'path': path.removeprefix('/nix/store/')}}
               and _output(node, 'out') == path and path not in valid, 'pending graph binding')
        if not node['name'].startswith('cargo-package-'):
            continue
        _check(drv in valid and all('/nix/store/' + s in valid for s in node['inputs']['srcs']),
               'unpack descriptor/input source missing')
        source_name = 'cargo-src-' + node['name'].removeprefix('cargo-package-')
        sources = []
        for dep, request in node['inputs']['drvs'].items():
            dep_path = _path('/nix/store/' + dep)
            _check(dep_path.endswith('.drv') and dep_path in valid, 'dependency descriptor missing')
            _check(set(request) == {'outputs', 'dynamicOutputs'}
                   and not request['dynamicOutputs'] and request['outputs']
                   and len(set(request['outputs'])) == len(request['outputs']), 'dependency request')
            dependency = graph[dep]
            for output in request['outputs']:
                dep_out = _output(dependency, output)
                _check(dep_out in valid, 'unqualified uncached unpack descendant')
                if dependency['name'].startswith('cargo-src-'):
                    info = dependency['outputs'][output]
                    _check(dependency['name'] == source_name and output == 'out'
                           and set(info) == {'method', 'hash'} and info['method'] == 'flat'
                           and info['hash'].startswith('sha256-'), 'original source FOD binding')
                    sources.append(dep_out)
        _check(len(sources) == 1, 'unpack must select exactly one original source FOD')
        selected.append(dict(row))
    selected.sort(key=lambda row: row['derivationPath'])
    _check(len({row['storePath'] for row in selected}) == len(selected), 'duplicate unpack output')
    batches = [selected[i:i + 16] for i in range(0, len(selected), 16)]
    _check(sum(map(len, batches)) == len(selected), 'unpack conservation')
    return batches
