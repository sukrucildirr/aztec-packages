use crate::kernel_circuit_public_inputs_composer::KernelCircuitPublicInputsComposer;
use dep::types::{
    abis::{
    private_kernel_data::{PrivateKernelData, verify_previous_kernel_proof},
    kernel_circuit_public_inputs::KernelCircuitPublicInputs, note_hash::ScopedNoteHash,
    nullifier::ScopedNullifier, log_hash::{LogHash, NoteLogHash}
},
    constants::{
    MAX_NEW_NOTE_HASHES_PER_TX, MAX_NEW_NULLIFIERS_PER_TX, MAX_NOTE_HASH_READ_REQUESTS_PER_TX,
    MAX_NULLIFIER_KEY_VALIDATION_REQUESTS_PER_TX, MAX_ENCRYPTED_LOGS_PER_TX,
    MAX_UNENCRYPTED_LOGS_PER_TX, MAX_NOTE_ENCRYPTED_LOGS_PER_TX
},
    grumpkin_private_key::GrumpkinPrivateKey, utils::arrays::array_length, traits::is_empty
};

struct PrivateKernelTailHints {
    sorted_new_note_hashes: [ScopedNoteHash; MAX_NEW_NOTE_HASHES_PER_TX],
    sorted_new_note_hashes_indexes: [u64; MAX_NEW_NOTE_HASHES_PER_TX],
    sorted_new_nullifiers: [ScopedNullifier; MAX_NEW_NULLIFIERS_PER_TX],
    sorted_new_nullifiers_indexes: [u64; MAX_NEW_NULLIFIERS_PER_TX],
    sorted_note_encrypted_log_hashes: [NoteLogHash; MAX_NOTE_ENCRYPTED_LOGS_PER_TX],
    sorted_note_encrypted_log_hashes_indexes: [u64; MAX_NOTE_ENCRYPTED_LOGS_PER_TX],
    sorted_encrypted_log_hashes: [LogHash; MAX_ENCRYPTED_LOGS_PER_TX],
    sorted_encrypted_log_hashes_indexes: [u64; MAX_ENCRYPTED_LOGS_PER_TX],
    sorted_unencrypted_log_hashes: [LogHash; MAX_UNENCRYPTED_LOGS_PER_TX],
    sorted_unencrypted_log_hashes_indexes: [u64; MAX_UNENCRYPTED_LOGS_PER_TX],
}

struct PrivateKernelTailCircuitPrivateInputs {
    previous_kernel: PrivateKernelData,
    hints: PrivateKernelTailHints,
}

impl PrivateKernelTailCircuitPrivateInputs {
    pub fn execute(self) -> KernelCircuitPublicInputs {
        let previous_public_inputs = self.previous_kernel.public_inputs;
        assert_eq(
            array_length(previous_public_inputs.end.public_call_stack), 0, "Public call stack must be empty when executing the tail circuit"
        );
        assert(
            is_empty(previous_public_inputs.public_teardown_call_request) == true, "Public teardown call request must be empty when executing the tail circuit"
        );

        // verify/aggregate the previous kernel
        verify_previous_kernel_proof(self.previous_kernel);

        KernelCircuitPublicInputsComposer::new(
            self.previous_kernel,
            self.hints.sorted_new_note_hashes,
            self.hints.sorted_new_note_hashes_indexes,
            self.hints.sorted_new_nullifiers,
            self.hints.sorted_new_nullifiers_indexes,
            self.hints.sorted_note_encrypted_log_hashes,
            self.hints.sorted_note_encrypted_log_hashes_indexes,
            self.hints.sorted_encrypted_log_hashes,
            self.hints.sorted_encrypted_log_hashes_indexes,
            self.hints.sorted_unencrypted_log_hashes,
            self.hints.sorted_unencrypted_log_hashes_indexes
        ).compose().finish()
    }
}

mod tests {
    use crate::private_kernel_tail::{PrivateKernelTailCircuitPrivateInputs, PrivateKernelTailHints};
    use dep::reset_kernel_lib::{
        tests::{
        note_hash_read_request_hints_builder::NoteHashReadRequestHintsBuilder,
        nullifier_read_request_hints_builder::NullifierReadRequestHintsBuilder,
        squash_transient_data::{squash_transient_note_hashes, squash_transient_nullifiers, squash_transient_logs}
    },
        reset::read_request::{PendingReadHint, ReadRequestState, ReadRequestStatus}
    };
    use dep::types::constants::{
        MAX_NOTE_HASH_READ_REQUESTS_PER_TX, MAX_NEW_NOTE_HASHES_PER_TX, MAX_NEW_NULLIFIERS_PER_TX,
        MAX_NULLIFIER_READ_REQUESTS_PER_TX, MAX_NULLIFIER_KEY_VALIDATION_REQUESTS_PER_TX,
        MAX_ENCRYPTED_LOGS_PER_TX, MAX_UNENCRYPTED_LOGS_PER_TX, MAX_NOTE_ENCRYPTED_LOGS_PER_TX,
        DA_BYTES_PER_FIELD, DA_GAS_PER_BYTE
    };
    use dep::types::{
        abis::{
        kernel_circuit_public_inputs::KernelCircuitPublicInputs, max_block_number::MaxBlockNumber,
        note_hash::{NoteHash, ScopedNoteHash}, nullifier::{Nullifier, ScopedNullifier},
        log_hash::{LogHash, NoteLogHash}, gas::Gas
    },
        address::AztecAddress, grumpkin_private_key::GrumpkinPrivateKey,
        hash::{compute_note_hash_nonce, compute_unique_note_hash, sha256_to_field, silo_note_hash, silo_nullifier},
        tests::{fixture_builder::FixtureBuilder, sort::sort_get_sorted_hints},
        utils::{arrays::{array_eq, array_length}}, traits::{Empty, is_empty, is_empty_array},
        grumpkin_point::GrumpkinPoint
    };

    // TODO: Reduce the duplicated code/tests for PrivateKernelTailInputs and PrivateKernelTailToPublicInputs.
    struct PrivateKernelTailInputsBuilder {
        previous_kernel: FixtureBuilder,
        transient_nullifier_indexes_for_note_hashes: [u64; MAX_NEW_NOTE_HASHES_PER_TX],
        transient_note_hash_indexes_for_nullifiers: [u64; MAX_NEW_NULLIFIERS_PER_TX],
        transient_note_hash_indexes_for_logs: [u64; MAX_NOTE_ENCRYPTED_LOGS_PER_TX],
        note_hash_read_request_hints_builder: NoteHashReadRequestHintsBuilder,
        nullifier_read_request_hints_builder: NullifierReadRequestHintsBuilder,
    }

    impl PrivateKernelTailInputsBuilder {
        pub fn new() -> Self {
            let mut previous_kernel = FixtureBuilder::new();
            previous_kernel.tx_context.gas_settings.gas_limits = Gas::new(1_000_000, 1_000_000);

            previous_kernel.append_new_nullifiers(1);

            PrivateKernelTailInputsBuilder {
                previous_kernel,
                transient_nullifier_indexes_for_note_hashes: [MAX_NEW_NULLIFIERS_PER_TX; MAX_NEW_NOTE_HASHES_PER_TX],
                transient_note_hash_indexes_for_nullifiers: [MAX_NEW_NOTE_HASHES_PER_TX; MAX_NEW_NULLIFIERS_PER_TX],
                transient_note_hash_indexes_for_logs: [MAX_NEW_NOTE_HASHES_PER_TX; MAX_NOTE_ENCRYPTED_LOGS_PER_TX],
                note_hash_read_request_hints_builder: NoteHashReadRequestHintsBuilder::new(MAX_NOTE_HASH_READ_REQUESTS_PER_TX),
                nullifier_read_request_hints_builder: NullifierReadRequestHintsBuilder::new(MAX_NULLIFIER_READ_REQUESTS_PER_TX)
            }
        }

        // A helper function that uses the first nullifer in the previous kernel to compute the unique siloed
        // note_hashes for the given note_hashes.
        pub fn compute_output_note_hashes<N>(self, note_hashes: [ScopedNoteHash; N]) -> [Field; N] {
            let first_nullifier = self.previous_kernel.new_nullifiers.get_unchecked(0);
            let mut output = [0; N];
            for i in 0..N {
                let note_hash = note_hashes[i];
                if note_hash.value() != 0 {
                    let nonce = compute_note_hash_nonce(first_nullifier.value(), i);
                    let unique_note_hash = compute_unique_note_hash(nonce, note_hash.value());
                    output[i] = silo_note_hash(note_hash.contract_address, unique_note_hash);
                }
            }
            output
        }

        pub fn compute_output_nullifiers<N>(_self: Self, nullifiers: [ScopedNullifier; N]) -> [Field; N] {
            let mut output = [0; N];
            output[0] = nullifiers[0].value();
            for i in 1..N {
                output[i] = silo_nullifier(nullifiers[i].contract_address, nullifiers[i].value());
            }
            output
        }

        pub fn execute(&mut self) -> KernelCircuitPublicInputs {
            let sorted = sort_get_sorted_hints(
                self.previous_kernel.new_note_hashes.storage,
                |a: ScopedNoteHash, b: ScopedNoteHash| a.counter() < b.counter()
            );
            let sorted_new_note_hashes = sorted.sorted_array;
            let sorted_new_note_hashes_indexes = sorted.sorted_index_hints;

            let sorted = sort_get_sorted_hints(
                self.previous_kernel.new_nullifiers.storage,
                |a: ScopedNullifier, b: ScopedNullifier| a.counter() < b.counter()
            );
            let sorted_new_nullifiers = sorted.sorted_array;
            let sorted_new_nullifiers_indexes = sorted.sorted_index_hints;

            let sorted = sort_get_sorted_hints(
                self.previous_kernel.note_encrypted_logs_hashes.storage,
                |a: NoteLogHash, b: NoteLogHash| a.counter < b.counter
            );
            let sorted_note_encrypted_log_hashes = sorted.sorted_array;
            let sorted_note_encrypted_log_hashes_indexes = sorted.sorted_index_hints;

            let sorted = sort_get_sorted_hints(
                self.previous_kernel.encrypted_logs_hashes.storage,
                |a: LogHash, b: LogHash| a.counter < b.counter
            );
            let sorted_encrypted_log_hashes = sorted.sorted_array;
            let sorted_encrypted_log_hashes_indexes = sorted.sorted_index_hints;

            let sorted = sort_get_sorted_hints(
                self.previous_kernel.unencrypted_logs_hashes.storage,
                |a: LogHash, b: LogHash| a.counter < b.counter
            );
            let sorted_unencrypted_log_hashes = sorted.sorted_array;
            let sorted_unencrypted_log_hashes_indexes = sorted.sorted_index_hints;

            let mut sorted_transient_nullifier_indexes_for_note_hashes = [MAX_NEW_NULLIFIERS_PER_TX; MAX_NEW_NOTE_HASHES_PER_TX];
            for i in 0..self.transient_nullifier_indexes_for_note_hashes.len() {
                let old_index = self.transient_nullifier_indexes_for_note_hashes[i];
                if old_index != MAX_NEW_NULLIFIERS_PER_TX {
                    let new_note_hash_index = sorted_new_note_hashes_indexes[i];
                    sorted_transient_nullifier_indexes_for_note_hashes[new_note_hash_index] = sorted_new_nullifiers_indexes[old_index];
                }
            }

            let mut sorted_transient_note_hash_indexes_for_nullifiers = [MAX_NEW_NOTE_HASHES_PER_TX; MAX_NEW_NULLIFIERS_PER_TX];
            for i in 0..self.transient_note_hash_indexes_for_nullifiers.len() {
                let old_index = self.transient_note_hash_indexes_for_nullifiers[i];
                if old_index != MAX_NEW_NOTE_HASHES_PER_TX {
                    let new_nullifier_index = sorted_new_nullifiers_indexes[i];
                    sorted_transient_note_hash_indexes_for_nullifiers[new_nullifier_index] = sorted_new_note_hashes_indexes[old_index];
                }
            }

            let hints = PrivateKernelTailHints {
                sorted_new_note_hashes,
                sorted_new_note_hashes_indexes,
                sorted_new_nullifiers,
                sorted_new_nullifiers_indexes,
                sorted_note_encrypted_log_hashes,
                sorted_note_encrypted_log_hashes_indexes,
                sorted_encrypted_log_hashes,
                sorted_encrypted_log_hashes_indexes,
                sorted_unencrypted_log_hashes,
                sorted_unencrypted_log_hashes_indexes
            };

            let kernel = PrivateKernelTailCircuitPrivateInputs { previous_kernel: self.previous_kernel.to_private_kernel_data(), hints };
            kernel.execute()
        }

        pub fn failed(&mut self) {
            let _ = self.execute();
        }

        pub fn succeeded(&mut self) {
            let _ = self.execute();
        }
    }

    #[test]
    unconstrained fn execution_succeeded() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        let public_inputs = builder.execute();

        assert(is_empty(public_inputs.start_state));
    }

    #[test]
    unconstrained fn propagate_previous_kernel_max_block_number() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.max_block_number = MaxBlockNumber::new(13);
        let public_inputs = builder.execute();

        assert_eq(public_inputs.rollup_validation_requests.max_block_number.unwrap(), 13);
    }

    #[test]
    unconstrained fn logs_are_handled_as_expected() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        // Logs for the previous call stack.
        let prev_encrypted_logs_hash = 80;
        let prev_encrypted_log_preimages_length = 13;
        let prev_unencrypted_logs_hash = 956;
        let prev_unencrypted_log_preimages_length = 24;
        builder.previous_kernel.set_encrypted_logs(prev_encrypted_logs_hash, prev_encrypted_log_preimages_length);
        builder.previous_kernel.set_unencrypted_logs(
            prev_unencrypted_logs_hash,
            prev_unencrypted_log_preimages_length
        );
        // Logs for the current call stack.
        let unencrypted_logs_hash = 26;
        let unencrypted_log_preimages_length = 50;
        builder.previous_kernel.set_unencrypted_logs(unencrypted_logs_hash, unencrypted_log_preimages_length);

        let public_inputs = builder.execute();

        assert_eq(public_inputs.end.encrypted_log_preimages_length, prev_encrypted_log_preimages_length);
        assert_eq(
            public_inputs.end.unencrypted_log_preimages_length, unencrypted_log_preimages_length + prev_unencrypted_log_preimages_length
        );

        // noir-fmt:ignore
        let hash_bytes: [u8; MAX_ENCRYPTED_LOGS_PER_TX * 32] = prev_encrypted_logs_hash
            .to_be_bytes(32)
            .append(&[0; MAX_ENCRYPTED_LOGS_PER_TX * 32 - 32])
            .as_array();
        let expected_encrypted_logs_hash = sha256_to_field(hash_bytes);
        assert_eq(public_inputs.end.encrypted_logs_hash, expected_encrypted_logs_hash);

        // noir-fmt:ignore
        let hash_bytes: [u8; MAX_UNENCRYPTED_LOGS_PER_TX * 32] = prev_unencrypted_logs_hash
            .to_be_bytes(32)
            .append(unencrypted_logs_hash.to_be_bytes(32))
            .append(&[0; MAX_UNENCRYPTED_LOGS_PER_TX * 32 - 64])
            .as_array();
        let expected_unencrypted_logs_hash = sha256_to_field(hash_bytes);
        assert_eq(public_inputs.end.unencrypted_logs_hash, expected_unencrypted_logs_hash);
    }

    #[test]
    unconstrained fn ordering_of_note_hashes_and_nullifiers() {
        let mut builder = PrivateKernelTailInputsBuilder::new();

        builder.previous_kernel.append_new_note_hashes(10, false);
        builder.previous_kernel.append_new_nullifiers(10);

        let sorted_note_hashes = builder.previous_kernel.new_note_hashes.storage;
        let sorted_nullifiers = builder.previous_kernel.new_nullifiers.storage;

        let mut reversed_note_hashes = [ScopedNoteHash::empty(); 10];
        let mut reversed_nullifiers = [ScopedNullifier::empty(); 10];

        for i in 0..10 {
            reversed_note_hashes[9 - i] = builder.previous_kernel.new_note_hashes.pop();
            reversed_nullifiers[9 - i] = builder.previous_kernel.new_nullifiers.pop();
        }

        builder.previous_kernel.new_note_hashes.extend_from_array(reversed_note_hashes);
        builder.previous_kernel.new_nullifiers.extend_from_array(reversed_nullifiers);

        let public_inputs = builder.execute();

        let expected_note_hashes = builder.compute_output_note_hashes(sorted_note_hashes);
        let expected_nullifiers = builder.compute_output_nullifiers(sorted_nullifiers);
        for i in 0..10 {
            assert(public_inputs.end.new_note_hashes[i].eq(expected_note_hashes[i]));
            assert(public_inputs.end.new_nullifiers[i].eq(expected_nullifiers[i]));
        }
    }

    #[test]
    unconstrained fn native_empty_nullified_note_hash_means_persistent_nullifier_0() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.append_new_note_hashes(2, false);
        builder.previous_kernel.append_new_nullifiers(2);
        let public_inputs = builder.execute();
        assert_eq(array_length(public_inputs.end.new_note_hashes), 2);
        assert_eq(array_length(public_inputs.end.new_nullifiers), 3);
        let expected_gas = Gas::tx_overhead() + Gas::new(DA_GAS_PER_BYTE * DA_BYTES_PER_FIELD * 5, 0);
        assert_eq(public_inputs.end.gas_used, expected_gas);
    }

    #[test(should_fail_with="Private call stack must be empty when executing the tail circuit")]
    unconstrained fn non_empty_private_call_stack_should_fail() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.push_private_call_request(1, false);
        builder.failed();
    }

    #[test(should_fail_with="Public call stack must be empty when executing the tail circuit")]
    unconstrained fn non_empty_public_call_stack_should_fail() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.push_public_call_request(1, false);
        builder.failed();
    }

    #[test(should_fail_with="Public teardown call request must be empty when executing the tail circuit")]
    unconstrained fn non_empty_public_teardown_call_request_should_fail() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.set_public_teardown_call_request(1, false);
        builder.failed();
    }

    #[test(should_fail_with="Non empty note hash read requests")]
    unconstrained fn non_empty_note_hash_read_requests() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.append_new_note_hashes(3, false);
        let _void = builder.previous_kernel.add_read_request_for_pending_note_hash(1);
        builder.failed();
    }

    #[test(should_fail_with="Non empty nullifier read requests")]
    unconstrained fn non_empty_nullifier_read_requests() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.append_new_nullifiers(3);
        let _void = builder.previous_kernel.add_read_request_for_pending_nullifier(1);
        builder.failed();
    }

    #[test(should_fail_with="Non empty nullifier key validation requests")]
    unconstrained fn non_empty_nullifier_key_validations() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        let _void = builder.previous_kernel.add_request_for_nullifier_key_validation(GrumpkinPoint::new(1, 2), 27);
        builder.failed();
    }

    #[test]
    unconstrained fn empty_tx_consumes_teardown_limits_plus_fixed_gas() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.tx_context.gas_settings.teardown_gas_limits = Gas::new(300, 300);
        let public_inputs = builder.execute();

        // addition follows the form:
        // teardown gas
        // tx overhead
        // tx nullifier
        let expected_gas_consumed = Gas::new(300, 300)
            + Gas::tx_overhead()
            + Gas::new(DA_GAS_PER_BYTE * DA_BYTES_PER_FIELD * 1, 0);
        assert_eq(public_inputs.end.gas_used, expected_gas_consumed);
    }

    #[test(should_fail_with="The gas used exceeds the gas limits")]
    unconstrained fn gas_limits_are_enforced() {
        let mut builder = PrivateKernelTailInputsBuilder::new();
        builder.previous_kernel.tx_context.gas_settings.teardown_gas_limits = Gas::new(300, 300);
        builder.previous_kernel.tx_context.gas_settings.gas_limits = Gas::new(1, 1);
        builder.failed();
    }

    #[test]
    unconstrained fn propagate_fee_payer() {
        // Check that we carry forward if the fee payer is already set
        let mut builder = PrivateKernelTailInputsBuilder::new();
        let fee_payer = AztecAddress::from_field(123);
        builder.previous_kernel.fee_payer = fee_payer;
        let public_inputs = builder.execute();
        assert_eq(public_inputs.fee_payer, fee_payer);

        // Check that the fee payer remains empty if unset
        let mut builder = PrivateKernelTailInputsBuilder::new();
        let public_inputs = builder.execute();
        assert_eq(public_inputs.fee_payer, AztecAddress::empty());
    }
}
