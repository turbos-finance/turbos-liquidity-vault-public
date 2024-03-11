// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::strategy {
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::bag::{Self, Bag};
    use sui::linked_table::{Self, LinkedTable};
    use sui::transfer;
    use std::type_name::{Self, TypeName};
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use std::option::{Self, Option};
    use turbos_clmm::position_nft::{Self, TurbosPositionNFT};
    use turbos_assets_manage::vault::{Self, Vault};
    use turbos_clmm::pool::{Self, Pool, Versioned};
    use turbos_assets_manage::config::{Self, GlobalConfig, OperatorCap};

    friend turbos_assets_manage::router;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidAmount: u64 = 1;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<

    struct StrategyAdminCap has key, store { id: UID }

    struct Strategy<phantom CoinTypeA, phantom CoinTypeB> has key, store {
        id: UID,
        clmm_pool_id: ID,
        coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
        fee_type_name: TypeName,
    }

    fun init(ctx: &mut TxContext) {
        init_(ctx);
    }

    fun init_(ctx: &mut TxContext) {
        transfer::transfer(StrategyAdminCap { id: object::new(ctx) }, tx_context::sender(ctx));
    }

    public(friend) fun create_strategy<CoinTypeA, CoinTypeB, FeeType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        clmm_pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
        ctx: &mut TxContext
    ): Strategy<CoinTypeA, CoinTypeB> {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        let clmm_pool_id = object::id(clmm_pool);
        let coin_a_type_name = type_name::get<CoinTypeA>();
        let coin_b_type_name = type_name::get<CoinTypeB>();
        let fee_type_name = type_name::get<FeeType>();
        let strategy = Strategy {
            id: object::new(ctx), 
            clmm_pool_id,
            coin_a_type_name,
            coin_b_type_name,
            fee_type_name,
        };

        strategy
    }
}