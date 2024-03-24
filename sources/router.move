// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::router {
    use std::string::{Self, String};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::vec_map::{Self, VecMap};
    use turbos_clmm::i32::{Self, I32};
    use sui::coin::{Self, Coin};
    use turbos_assets_manage::config::{Self, AdminCap, GlobalConfig, OperatorCap};
    use turbos_assets_manage::vault::{Self, Vault, Strategy};
    use turbos_clmm::pool::{Self, Pool, Versioned, PoolRewardVault};
    use turbos_clmm::position_manager::{Self, Positions};
    use turbos_clmm::full_math_u128;
    use sui::clock::{Self, Clock};
    use turbos_assets_manage::rewarder::{Self, RewarderManager};

    entry public fun set_roles(admin_cap: &AdminCap, config: &mut GlobalConfig, account_address: address, role: u128) {
        config::set_roles(admin_cap, config, account_address, role);
    }

    entry public fun add_role(admin_cap: &AdminCap, config: &mut GlobalConfig, account_address: address, role_id: u8) {
        config::add_role(admin_cap, config, account_address, role_id);
    }

    entry public fun remove_role(admin_cap: &AdminCap, config: &mut GlobalConfig, account_address: address, role_id: u8) {
        config::remove_role(admin_cap, config, account_address, role_id);
    }

    entry public fun add_operator(admin_cap: &AdminCap, config: &mut GlobalConfig, role: u128, operator_address: address, tx_context: &mut TxContext) {
        config::add_operator(admin_cap, config, role, operator_address, tx_context);
    }

    entry public fun set_package_version(admin_cap: &AdminCap, config: &mut GlobalConfig, new_version: u64) {
        config::set_package_version(admin_cap, config, new_version);
    }

    entry fun create_strategy<CoinTypeA, CoinTypeB, FeeType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        clmm_pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
        effective_tick_lower: u32,
        effective_tick_lower_is_neg: bool,
        effective_tick_upper: u32,
        effective_tick_upper_is_neg: bool,
        image_url: String,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let effective_tick_lower_i32 = i32::from_u32_neg(effective_tick_lower, effective_tick_lower_is_neg);
        let effective_tick_upper_i32 = i32::from_u32_neg(effective_tick_upper, effective_tick_upper_is_neg);
        let strategy = vault::create_strategy<CoinTypeA, CoinTypeB, FeeType>(
            operator_cap,
            global_config,
            rewarder_manager,
            clmm_pool,
            effective_tick_lower_i32,
            effective_tick_upper_i32,
            image_url,
            ctx,
        );

        transfer::public_transfer(strategy, sender)
    }

    entry public fun open_vault<CoinTypeA, CoinTypeB>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        base_tick_lower_index: u32,
        base_tick_lower_index_is_neg: bool,
        base_tick_upper_index: u32,
        base_tick_upper_index_is_neg: bool,
        limit_tick_lower_index: u32,
        limit_tick_lower_index_is_neg: bool,
        limit_tick_upper_index: u32,
        limit_tick_upper_index_is_neg: bool,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let base_tick_lower_index_i32 = i32::from_u32_neg(base_tick_lower_index, base_tick_lower_index_is_neg);
        let base_tick_upper_index_i32 = i32::from_u32_neg(base_tick_upper_index, base_tick_upper_index_is_neg);
        let limit_tick_lower_index_i32 = i32::from_u32_neg(limit_tick_lower_index, limit_tick_lower_index_is_neg);
        let limit_tick_upper_index_i32 = i32::from_u32_neg(limit_tick_upper_index, limit_tick_upper_index_is_neg);
        let vault = vault::open_vault<CoinTypeA, CoinTypeB>(
            global_config,
            strategy,
            base_tick_lower_index_i32,
            base_tick_upper_index_i32,
            limit_tick_lower_index_i32,
            limit_tick_upper_index_i32,
            ctx,
        );

        transfer::public_transfer(vault, recipient)
    }

    entry public fun close_vault<CoinTypeA, CoinTypeB>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault: Vault,
        ctx: &mut TxContext
    ) {
        vault::close_vault<CoinTypeA, CoinTypeB>(
            global_config,
            strategy,
            vault,
            ctx,
        )
    }

    entry public fun deposit<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        vault::deposit(
            global_config,
            rewarder_manager,
            strategy,
            vault,
            clmm_pool,
            clmm_positions,
            coin_a,
            coin_b,
            clock,
            clmm_versioned,
            ctx
        );
    }

    entry public fun withdraw<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        percentage: u64, //0~100
        burn_clmm_nft: bool,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let (coin_a, coin_b) = vault::withdraw(
            global_config,
            rewarder_manager,
            strategy,
            vault,
            clmm_pool,
            clmm_positions,
            percentage,
            burn_clmm_nft,
            clock,
            clmm_versioned,
            ctx
        );

        transfer::public_transfer(coin_a, recipient);
        transfer::public_transfer(coin_b, recipient);
    }

    entry public fun collect_clmm_reward_direct_return<CoinTypeA, CoinTypeB, FeeType, RewardCoinType>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoinType>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let reward = vault::collect_clmm_reward_direct_return(
            global_config,
            strategy,
            vault,
            clmm_pool,
            clmm_positions,
            clmm_reward_vault,
            clmm_reward_index,
            recipient,
            clock,
            clmm_versioned,
            ctx
        );

        transfer::public_transfer(reward, recipient);
    }

    entry public fun collect_protocol_fee<BalanceType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let coin = vault::collect_protocol_fee<BalanceType>(
            operator_cap,
            global_config,
            strategy,
            amount,
            ctx,
        );

        transfer::public_transfer(coin, recipient);
    }
}