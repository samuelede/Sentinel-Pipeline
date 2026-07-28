"""Basic sanity checks on schema contracts. Extend with real fixtures per dataset."""

from validators.contracts import CONTRACTS


def test_all_contracts_have_required_not_null_subset_of_columns():
    for dataset, contract in CONTRACTS.items():
        columns = set(contract["columns"])
        required = set(contract.get("required_not_null", []))
        assert required.issubset(columns), (
            f"{dataset}: required_not_null contains a column not in the schema"
        )


def test_claims_fact_has_expected_primary_key_column():
    assert "claim_id" in CONTRACTS["claims_fact"]["columns"]
