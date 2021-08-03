# Nimbus - Binary compatibility on the host side of the EVMC API interface
#
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#{.push raises: [Defect].}

when not declaredInScope(included_from_host_services):
  {.error: "Do not import this file directly, import host_services instead".}

import evmc/evmc, ./evmc_dynamic_loader

template toHost(p: evmc_host_context): TransactionHost =
  cast[TransactionHost](p)

proc accountExists(p: evmc_host_context, address: var evmc_address): c99bool {.cdecl.} =
  toHost(p).accountExists(address.fromEvmc)

proc getStorage(p: evmc_host_context, address: var evmc_address,
                key: var evmc_bytes32): evmc_bytes32 {.cdecl.} =
  toHost(p).getStorage(address.fromEvmc, key.flip256.fromEvmc).toEvmc.flip256

proc setStorage(p: evmc_host_context, address: var evmc_address,
                key, value: var evmc_bytes32): evmc_storage_status {.cdecl.} =
  toHost(p).setStorage(address.fromEvmc, key.flip256.fromEvmc, value.flip256.fromEvmc)

proc getBalance(p: evmc_host_context,
                address: var evmc_address): evmc_uint256be {.cdecl.} =
    toHost(p).getBalance(address.fromEvmc).toEvmc.flip256

proc getCodeSize(p: evmc_host_context,
                 address: var evmc_address): csize_t {.cdecl.} =
    toHost(p).getCodeSize(address.fromEvmc)

proc getCodeHash(p: evmc_host_context,
                 address: var evmc_address): evmc_bytes32 {.cdecl.} =
    toHost(p).getCodeHash(address.fromEvmc).toEvmc

proc copyCode(p: evmc_host_context, address: var evmc_address, code_offset: csize_t,
              buffer_data: ptr byte, buffer_size: csize_t): csize_t {.cdecl.} =
    toHost(p).copyCode(address.fromEvmc, code_offset, buffer_data, buffer_size)

proc selfDestruct(p: evmc_host_context, address,
                  beneficiary: var evmc_address) {.cdecl.} =
  toHost(p).selfDestruct(address.fromEvmc, beneficiary.fromEvmc)

proc call(p: evmc_host_context, msg: var evmc_message): evmc_result {.cdecl.} =
  var msg = msg # Make a local copy that's ok to modify.
  msg.value = flip256(msg.value)
  toHost(p).call(msg)

proc getTxContext(p: evmc_host_context): evmc_tx_context {.cdecl.} =
  result = toHost(p).getTxContext()
  result.tx_gas_price = flip256(result.tx_gas_price)
  result.block_difficulty = flip256(result.block_difficulty)
  result.chain_id = flip256(result.chain_id)

proc getBlockHash(p: evmc_host_context, number: int64): evmc_bytes32 {.cdecl.} =
  # TODO: `HostBlockNumber` is 256-bit unsigned.  It should be changed to match
  # EVMC which is more sensible.
  toHost(p).getBlockHash(number.uint64.u256).toEvmc

proc emitLog(p: evmc_host_context, address: var evmc_address,
             data: ptr byte, data_size: csize_t,
             topics: ptr evmc_bytes32, topics_count: csize_t) {.cdecl.} =
  toHost(p).emitLog(address.fromEvmc, data, data_size,
                    cast[ptr HostTopic](topics), topics_count)

proc evmcGetHostInterface(): ref evmc_host_interface =
  var theHostInterface {.global, threadvar.}: ref evmc_host_interface
  if theHostInterface.isNil:
    theHostInterface = (ref evmc_host_interface)(
      account_exists: accountExists,
      get_storage:    getStorage,
      set_storage:    setStorage,
      get_balance:    getBalance,
      get_code_size:  getCodeSize,
      get_code_hash:  getCodeHash,
      copy_code:      copyCode,
      selfdestruct:   selfDestruct,
      call:           call,
      get_tx_context: getTxContext,
      get_block_hash: getBlockHash,
      emit_log:       emitLog,
    )
  return theHostInterface

# This must be named `call` to show as "call" when traced by the `show` macro.
proc call(host: TransactionHost): EvmcResult {.show, inline.} =
  let vm = evmcLoadVMCached()
  if vm.isNil:
    echo "Warning: No EVM"
    # Nim defaults are fine for all other fields in the result object.
    return EvmcResult(status_code: EVMC_INTERNAL_ERROR)

  let hostInterface = evmcGetHostInterface()
  let hostContext = cast[evmc_host_context](host)

  # Without `{.gcsafe.}:` here, the call via `vm.execute` results in a Nim
  # compile-time error in a far away function.  Starting here, a cascade of
  # warnings takes place: "Warning: '...' is not GC-safe as it performs an
  # indirect call here [GCUnsafe2]", then a list of "Warning: '...' is not
  # GC-safe as it calls '...'" at each function up the call stack, to a high
  # level function `persistBlocks` where it terminates compilation as an error
  # instead of a warning.
  #
  # It is tempting to annotate all EVMC API functions with `{.cdecl, gcsafe.}`,
  # overriding the function signatures from the Nim EVMC module.  Perhaps we
  # will do that, though it's conceptually dubious, as the two sides of the
  # EVMC ABI live in different GC worlds (when loaded as a shared library with
  # its own Nim runtime), very similar to calling between threads.
  #
  # TODO: But wait: Why does the Nim EVMC test program compile fine without
  # any `gcsafe`, even with `--threads:on`?
  {.gcsafe.}:
    vm.execute(vm, hostInterface[].addr, hostContext,
               evmc_revision(host.vmState.fork), host.msg,
               if host.code.len > 0: host.code[0].unsafeAddr else: nil,
               host.code.len.csize_t)

proc evmcExecComputation*(host: TransactionHost): EvmcResult =
  call(host)
