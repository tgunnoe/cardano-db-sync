# Configuration

The initial design of db-sync was a one size fits all approach. It served as a general-purpose
backend for Cardano applications, including light wallets, explorers, etc. Over time, many new
features have been added, including historic rewards with Shelley, scripts with Allegra, multiassets
with Mary, Plutus scripts and redeemers with Alonzo, stake pool metadata with the integration of
SMASH, etc.

While db-sync needs to use the resources that all these features require, many applications use only
a small fraction of these features. Therefore, it is reasonable to introduce flags and options that
turn off some of these features, especially the most expensive ones in terms of performance. These
configuration options require proper documentation, which is presented below.

### --disable-ledger

One of the db-sync features that uses the most resources is that it maintains a ledger state and
replays all the ledger rules. This is the only way to get historic reward details and other data
that is not included in the blocks (ie. historic stake distribution, ada pots, epoch parameters,
etc). The flag --disable-ledger provides the option to turn off these features and significantly
reduce memory usage (by up to 10GB on mainnet) and sync time. Another benefit of this option is
that there are no rollbacks on startup, which tend to take quite some time, since there are no
ledger snapshots maintained on disk.

When this flag is enabled, some features are missing and some DB tables are left empty:
- `redeemer.fee` is left null
- `reward` table is left empty
- `epoch_stake` table is left empty
- `ada_pots` table is left empty
- `epoch_param` table is left empty
- `tx.deposit` is left null (too expensive to calculate without the ledger)
- `drep_distr` is left empty
- `governance_action.x_epoch` is left null
- `governance_action.expiration` is left null

Warning: Running db-sync with this flag and then restarting it without the flag will cause crashes and should be avoided.

Warning: It was previously required to still have a `--state-dir` option provided when in conjunction with `--disable-ledger`. This is no longer the case and now an error will occure if they are both present at the same time.

If used with docker, this flag can be provided as an extra flag to docker image.

Released snapshots are compatible with these options. Since the snapshots are created without the
option, there still can be some minor inconsistencies. The above data may exist up to the slot/epoch
of the snapshot creation and can be missing afterward. To fix this, when db-sync is initiated with
this flag, it will automatically remove all these data.

Warning: This will irreversibly delete data from existing snapshots.

Here are the exact queries db-sync with this flag will run after restoring a snapshot:

```sql
update redeemer set fee = null;
delete from reward;
delete from epoch_stake;
delete from ada_pots;
delete from epoch_param;
```

### --disable-cache : Experimental

This flag disables the application level caches of db-sync. It slightly reduces memory usage but
increases the syncing time. This flag is worth using only when experiencing significant memory
issues.

### --disable-epoch : Experimental

With this option the epoch table is left empty. Mostly left for historical reasons, since it
provides a negligible improvement in sync time.

### --disable-in-out : Experimental

Disables the inputs and outputs. With this flag
- `tx_in` table is left empty
- `tx_out` table is left empty
- `ma_tx_out` table is left empty
- `tx.fee` has a wrong value 0
- `redeemer.script_hash` is left Null

It's similar to `--bootstrap-tx-out` except the UTxO is never populated. However after using this
flag db-sync can be stopped and restarted with `--bootstrap-tx-out` to load the UTxO from the
ledger.

### --disable-shelley : Experimental

Disables the data related to shelley, all certificates, withdrawalsand  param proposals.
Doesn't disable `epoch_stake` and `rewards`, For this check `--disable-ledger`.

### --disable-multiassets : Experimental

Disables the multi assets tables and entries.

### --disable-metadata : Experimental

Disables the tx_metadata table.

### --disable-plutus-extra : Experimental

Disables most tables and entries related to plutus and scripts.

### --disable-offchain-pool-data : Experimental
_(previousle called --disable-offline-data)__

Disables fetching pool offchain metadata.

### --disable-gov : Experimental

Disables all data related to governance

### --disable-all : Experimental

Disables almost all data except `block`, `tx` and data related to the ledger state

### --dont-use-ledger : Experimental

Maintains the ledger state, but doesn't use any of its data, except to load UTxO. To be used with `--bootstrap-tx-out`

### --only-utxo : Experimental

This is the equivalent of using `--dont-use-ledger`
`--disable-shelley`, `--disable-plutus-extra`, `--disable-offchain-pool-data`, `--disable-gov`, `--bootstrap-tx-out`.
This mode initially populates only a few tables, like `block` and `tx`. It maintains a ledger state but doesn't use any of its data. When syncing is completed, it loads the whole UTxO set from the ledger to the `tx_out` and `ma_tx_out` tables.
After that db-sync can be restarted with `--disable-ledger-state` to continue
syncing without maintaining the ledger

### --only-gov : Experimental

Disables most data except governance data. This is the equivalent of using `--disable-in-out`,
`--disable-shelley`, `--disable-multiassets`, `--disable-plutus-extra`, `--disable-offchain-pool-data`,
with the only difference that it also disables the `reward` table even when the ledger is used.

### --consumed-tx-out

Adds a new field `tx_out (consumed_by_tx_id)` and populated it accordingly. This allows users to
query the tx_out table for unspent outputs directly, without the need to join with the tx_in table.
If this is set once, then it must be always be set on following executions of db-sync, unless
`prune-tx-out` is used instead.

### --prune-tx-out

If `prune-tx-out` is set it's assumed that --consumed-tx-out is also set, even if it's not.
This flag periodically prunes the consumed tx_out table. So it allows to query for utxo
without having to maintain the whole tx_out table. Deletes to `tx_out` are propagated to `ma_tx_out`
through foreign keys. If this is set once, then it must be always set on following executions of
db-sync. Failure to do this can result in crashed and db-sync currently has no way to detect it.

### --bootstrap-tx-out

This flag results in a similar db schema as using `--prune-tx-out`, except it syncs faster. The difference is that instead of inserting/updating/deleting outputs, it delays the insertion of
UTxO until the tip of the chain. By doing so, it avoid costly db operations for the majority of
outputs, that are eventually consumed and as a result deleted. UTxO are eventually
inserted in bulk from the ledger state.
The initial implementation of the feautures assumes using `--prune-tx-out` and not using `--disable-ledger`, since the ledger state is used. The networks needs to be in Babbage or Conway era for this to work.
Some field are left empty when using this flag, like
- `tx.fee` has a wrong value 0
- `redeemer.script_hash` is left Null

Until the ledger state migration happens any restart requires reusing the `--bootstrap-tx-out` flag. After it's completed the flag can be omitted on restarts.

### --keep-tx-metadata

This flag was introduced in v.13.2.0.0 as all postgres field with the type jsonb were removed to improve insertion performance.
If they are required and you have database queries against jsonb then activate this flag to re-introduce the type jsonb.
You can pass multiple values to the flag eg: `--keep-tx-metadata 1,2,3` make sure you are using commas between each key.
