# Leading hyphens in Linux licensing passwords

[Issue #365](https://github.com/abominableenterprise/yetikit/issues/365)

Installed the pinned Linux editor files with
`PROJECT="$PWD/Host" Tools/ship/linux-unity.sh setup --no-creds`. Ran only the
licensing client, in an isolated home with an empty environment apart from
paths, using `nobody@example.invalid` and the synthetic password
`-fakeHyphen123`. No editor was launched and no seat was used.

The client reported version `1.18.3+d7ffd15`; its dependency manifest lists
`CommandLineParser/2.9.1`, not `System.CommandLine`. Its help lists no stdin,
environment, or file input for the password. The Hub access-token file is a
separate authentication method.

| Password arguments | `--activate-ulf` | `--return-ulf` |
| --- | --- | --- |
| `--password -fakeHyphen123` | `UnknownOptionError` (33) | `UnknownOptionError` (33) |
| `--password=-fakeHyphen123` | Authentication rejected: Unauthorized (26) | No local ULF in the isolated home (28) |
| `--password:-fakeHyphen123` | `UnknownOptionError` (33) | `UnknownOptionError` (33) |
| `--password -- -fakeHyphen123` | `UnknownOptionError` (33) | `UnknownOptionError` (33) |

The `=` probes used `--username=nobody@example.invalid` as well. Both reached
the selected command beyond parsing; neither performed a successful license
transaction.
