// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::vault {
    use std::vector;
    use sui::transfer;
    use sui::display;
    use sui::package;
    use sui::bag::{Self, Bag};
    use sui::coin::{Self, Coin};
    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use sui::table::{Self, Table};
    use sui::linked_table::{Self, LinkedTable};
    use std::string::{Self, utf8, String};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use turbos_clmm::position_manager::{Self, Positions};
    use turbos_clmm::pool::{Self, Pool, Versioned, PoolRewardVault};
    use turbos_clmm::position_nft::{Self, TurbosPositionNFT};
    use turbos_clmm::i32::{Self, I32};
    use sui::clock::{Self, Clock};
    use turbos_assets_manage::config::{Self, GlobalConfig, OperatorCap};

    friend turbos_assets_manage::router;

    const MAX_U64: u64 = 0xffffffffffffffff;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidAmount: u64 = 1;
    const EInvalidPercentage: u64 = 2;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<

    struct VAULT has drop {}

    struct Account<phantom CoinTypeA, phantom CoinTypeB> has store {
        coin_a_balance: Balance<CoinTypeA>,
        coin_b_balance: Balance<CoinTypeB>,
        clmm_base_nft: Option<TurbosPositionNFT>,
        clmm_limit_nft: Option<TurbosPositionNFT>,
        // After rebalancing, the rewards that users have in clmm will be collected to this bag
        // and then the old NFT will be destroyed.
        reward_balances: Bag,
    }

    struct VaultManager<phantom CoinTypeA, phantom CoinTypeB> has key, store {
        id: UID,
         // The key is vault's vault id.
        vaults: LinkedTable<ID, VaultInfo>,
        vault_index: u64,
        // Map from vault id -> vault account.
        accounts: Table<ID, Account<CoinTypeA, CoinTypeB>>,
        // Map from user address -> vault id.
        // user_vaults: Table<address, u64>,
    }

    struct Vault has store, key {
	    id: UID,
        index: u64,
        strategy_id: ID,
	    coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
        name: String,
	    description: String,
	    url: String,
    }

    struct VaultInfo has copy, drop, store {
        vault_id: ID,
        strategy_id: ID,
        coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
        base_lower_index: I32,
        base_upper_index: I32,
        limit_lower_index: I32,
        limit_upper_index: I32,
    }

    fun init(vault: VAULT, ctx: &mut TxContext) {
        let display_keys = vector::empty();
        vector::push_back(&mut display_keys, utf8(b"name"));
        vector::push_back(&mut display_keys, utf8(b"coin_type_a"));
        vector::push_back(&mut display_keys, utf8(b"coin_type_b"));
        vector::push_back(&mut display_keys, utf8(b"description"));
        vector::push_back(&mut display_keys, utf8(b"image_url"));
        vector::push_back(&mut display_keys, utf8(b"project_url"));
        vector::push_back(&mut display_keys, utf8(b"creator"));

        let display_values = vector::empty();
        vector::push_back(&mut display_values, utf8(b"{name}"));
        vector::push_back(&mut display_values, utf8(b"{coin_type_a}"));
        vector::push_back(&mut display_values, utf8(b"{coin_type_b}"));
        vector::push_back(&mut display_values, utf8(b"{description}"));
        vector::push_back(&mut display_values, utf8(b"{img_url}"));
        vector::push_back(&mut display_values, utf8(b"https://turbos.finance"));
        vector::push_back(&mut display_values, utf8(b"Turbos Team"));

        let publisher = package::claim(vault, ctx);
        let display = display::new<Vault>(&publisher, ctx);

        display::add_multiple<Vault>(&mut display, display_keys, display_values);
        display::update_version<Vault>(&mut display);

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(display, tx_context::sender(ctx));
    }

    public(friend) fun create_vault_manager<CoinTypeA, CoinTypeB>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        ctx: &mut TxContext
    ): VaultManager<CoinTypeA, CoinTypeB> {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        let vaults = linked_table::new<ID, VaultInfo>(ctx);
        let vault_manager = VaultManager {
            id: object::new(ctx),
            vaults,
            vault_index: 0,
            accounts: table::new(ctx),
        };
        vault_manager
    }

    public fun open_vault<CoinTypeA, CoinTypeB>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        strategy_id: ID, 
        base_lower_index: I32,
        base_upper_index: I32,
        ctx: &mut TxContext
    ): Vault {
        config::checked_package_version(global_config);
        let vault_id = object::new(ctx);
        let coin_a_type_name = type_name::get<CoinTypeA>();
        let coin_b_type_name = type_name::get<CoinTypeB>();
        let new_vault_index = vault_manager.vault_index + 1;

        let vault = Vault {
            id: vault_id,
            index: new_vault_index,
            strategy_id,
            coin_a_type_name,
            coin_b_type_name,
            name: string::utf8(b"Turbos Vault's NFT"),
            description: string::utf8(b"Turbos Vault's NFT"),
            url: string::utf8(b"https://app.turbos.finance/icon/Turbos-30.svg"),
        };

        init_account_balance(vault_manager, object::id(&vault), ctx);

        let vault_info = VaultInfo {
            vault_id: object::id(&vault),
            strategy_id,
            coin_a_type_name,
            coin_b_type_name,
            base_lower_index,
            base_upper_index,
            limit_lower_index: i32::zero(),
            limit_upper_index: i32::zero(),
        };
        vault_manager.vault_index = new_vault_index;

        vault
    }

    public fun deposit<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        base_tick_lower_index: I32,
        base_tick_upper_index: I32,
        limit_tick_lower_index: I32,
        limit_tick_upper_index: I32,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        let sender = tx_context::sender(ctx);
        let vault_id = object::id(vault);
        assert!(coin::value(&coin_a) > 0 || coin::value(&coin_b) > 0, EInvalidAmount);
        increase_vault_balance(
            vault_manager, 
            vault,
            coin::into_balance(coin_a),
            coin::into_balance(coin_b),
        );
        let (balance_a, balance_b) = withdraw_vault_balance(vault_manager, vault_id);
            if (is_clmm_base_nft_exists(vault_manager, vault_id)) {
                increase_liquidity(
                    global_config,
                    vault_manager,
                    vault,
                    clmm_pool,
                    clmm_positions,
            coin::from_balance(balance_a, ctx),
            coin::from_balance(balance_b, ctx),
                    clock,
                    clmm_versioned,
                    ctx,
                );
            } else {
                mint_liquidity(
                    global_config,
                    vault_manager,
                    vault,
                    clmm_pool,
                    clmm_positions,
                    coin::from_balance(balance_a, ctx),
            coin::from_balance(balance_b, ctx),
                    base_tick_lower_index,
                    base_tick_upper_index,
                    limit_tick_lower_index,
                    limit_tick_upper_index,
                    clock,
                    clmm_versioned,
                    ctx,
                );
            }
    }

    public fun mint_liquidity<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        base_tick_lower_index: I32,
        base_tick_upper_index: I32,
        limit_tick_lower_index: I32,
        limit_tick_upper_index: I32,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        let sender = tx_context::sender(ctx);
        let vault_id = object::id(vault);
        assert!(coin::value(&coin_a) > 0 || coin::value(&coin_b) > 0, EInvalidAmount);
        let (nft, coin_a_left, coin_b_left) = mint_clmm_liquidity(
            clmm_pool,
            clmm_positions,
            coin_a,
            coin_b,
            base_tick_lower_index,
            base_tick_upper_index,
            clock,
            clmm_versioned,
            ctx,
        );
        fill_clmm_base_nft(vault_manager, vault_id, nft);

        if (!i32::lt(limit_tick_lower_index, limit_tick_upper_index)) {
            let (nft_limit, limit_coin_a_left, limit_coin_b_left) = mint_clmm_liquidity(
                clmm_pool,
                clmm_positions,
                coin_a_left,
                coin_b_left,
                limit_tick_lower_index,
                limit_tick_upper_index,
                clock,
                clmm_versioned,
                ctx,
            );
            fill_clmm_base_nft(vault_manager, vault_id, nft_limit);
            increase_vault_balance(
                vault_manager, 
                vault,
                coin::into_balance(limit_coin_a_left),
                coin::into_balance(limit_coin_b_left),
            );
        } else {
            increase_vault_balance(
                vault_manager, 
                vault,
                coin::into_balance(coin_a_left),
                coin::into_balance(coin_b_left),
            );
        }
    }

    public fun increase_liquidity<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        let sender = tx_context::sender(ctx);
        let vault_id = object::id(vault);
        assert!(coin::value(&coin_a) > 0 || coin::value(&coin_b) > 0, EInvalidAmount);
        // Add liquidity to existing base positions
        let nft = borrow_mut_clmm_base_nft(vault_manager, vault_id);
        let (coin_a_left, coin_b_left) = increase_clmm_liquidity(
            nft,
            clmm_pool,
            clmm_positions,
            coin_a,
            coin_b,
            clock,
            clmm_versioned,
            ctx,
        );
        let limit_nft = borrow_mut_clmm_limit_nft(vault_manager, vault_id);
        let (limit_coin_a_left, limit_coin_b_left) = increase_clmm_liquidity(
            limit_nft,
            clmm_pool,
            clmm_positions,
            coin_a_left,
            coin_b_left,
            clock,
            clmm_versioned,
            ctx,
        );
        increase_vault_balance(
            vault_manager, 
            vault,
            coin::into_balance(limit_coin_a_left),
            coin::into_balance(limit_coin_b_left),
        ) 
    }

    public fun withdraw<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        percentage: u64, //0~100
        burn_clmm_nft: bool,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
        config::checked_package_version(global_config);
        assert!(percentage > 0 && percentage <= 100, EInvalidPercentage);
        let vault_id = object::id(vault);
        collect_clmm_fees(
            vault_manager,
            vault,
            clmm_pool,
            clmm_positions,
            clock,
            clmm_versioned,
            ctx,
        );
        let nft = borrow_mut_clmm_base_nft(vault_manager, vault_id);
        let (_, _, liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(nft));
        let (base_coin_a, base_coin_b) = decrease_clmm_liquidity(
            nft,
            clmm_pool,
            clmm_positions,
            liquidity * 100 / (percentage as u128),
            clock,
            clmm_versioned,
            ctx,
        );
        increase_vault_balance(
            vault_manager, 
            vault,
            coin::into_balance(base_coin_a),
            coin::into_balance(base_coin_b),
        );
        let limit_nft = borrow_mut_clmm_limit_nft(vault_manager, vault_id);
        let (_, _, liquidity_limit) = position_manager::get_position_info(clmm_positions, object::id_address(limit_nft));
        let (limit_coin_a, limit_coin_b) = decrease_clmm_liquidity(
            limit_nft,
            clmm_pool,
            clmm_positions,
            liquidity_limit * 100 / (percentage as u128),
            clock,
            clmm_versioned,
            ctx,
        );
        increase_vault_balance(
            vault_manager, 
            vault,
            coin::into_balance(limit_coin_a),
            coin::into_balance(limit_coin_b),
        );
        let (amount_a, amount_b) = vault_balance(vault_manager, vault_id);
        let (balance_a, balance_b) = decrease_vault_balance(
            vault_manager, 
            vault_id,
            amount_a * 100 / percentage,
            amount_b * 100 / percentage,
        );
        if (burn_clmm_nft && percentage == 100) {
            burn_clmm_base_nft<CoinTypeA, CoinTypeB, FeeType>(
                vault_manager,
                vault_id,
                clmm_positions,
                clmm_versioned,
                ctx
            );
            burn_clmm_limit_nft<CoinTypeA, CoinTypeB, FeeType>(
                vault_manager,
                vault_id,
                clmm_positions,
                clmm_versioned,
                ctx
            );
        };

        (coin::from_balance(balance_a, ctx), coin::from_balance(balance_b, ctx))
    }

    public fun rebalance<CoinTypeA, CoinTypeB, FeeType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &mut Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        base_tick_lower_index: I32,
        base_tick_upper_index: I32,
        limit_tick_lower_index: I32,
        limit_tick_upper_index: I32,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_rebalance_manager_role(global_config, operator_address);

        let vault_id = object::id(vault);
        //withdraw all liquidity and burn clmm nft
        let (coin_a, coin_b) = withdraw(
            global_config,
            vault_manager,
            vault,
            clmm_pool,
            clmm_positions,
            100,
            true,
            clock,
            clmm_versioned,
            ctx,
        );

        mint_liquidity(
            global_config,
            vault_manager,
            vault,
            clmm_pool,
            clmm_positions,
            coin_a,
            coin_b,
            base_tick_lower_index,
            base_tick_upper_index,
            limit_tick_lower_index,
            limit_tick_upper_index,
            clock,
            clmm_versioned,
            ctx,
        );
    }

    fun mint_clmm_liquidity<CoinTypeA, CoinTypeB, FeeType>(
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        tick_lower_index: I32,
        tick_upper_index: I32,
        clock: &Clock,
        versioned: &Versioned,
        ctx: &mut TxContext
    ): (TurbosPositionNFT, Coin<CoinTypeA>, Coin<CoinTypeB>) {
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        let (nft, coin_a_left, coin_b_left) = position_manager::mint_with_return_(
            clmm_pool,
            clmm_positions,
            coin_to_vec(coin_a),
            coin_to_vec(coin_b),
            i32::abs_u32(tick_lower_index),
            i32::is_neg(tick_lower_index),
            i32::abs_u32(tick_upper_index),
            i32::is_neg(tick_upper_index),
            amount_a_desired,
            amount_b_desired,
            0,
            0,
            clock::timestamp_ms(clock) - 60000,
            clock,
            versioned,
            ctx,
        );

        (nft, coin_a_left, coin_b_left)
    }

    fun increase_clmm_liquidity<CoinTypeA, CoinTypeB, FeeType>(
        nft: &mut TurbosPositionNFT,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        clock: &Clock,
        versioned: &Versioned,
        ctx: &mut TxContext
    ): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        let (coin_a_left, coin_b_left) = position_manager::increase_liquidity_with_return_(
            clmm_pool,
            clmm_positions,
            coin_to_vec(coin_a),
            coin_to_vec(coin_b),
            nft,
            amount_a_desired,
            amount_b_desired,
            0,
            0,
            clock::timestamp_ms(clock) - 60000,
            clock,
            versioned,
            ctx,
        );

        (coin_a_left, coin_b_left)
    }

    fun decrease_clmm_liquidity<CoinTypeA, CoinTypeB, FeeType>(
        nft: &mut TurbosPositionNFT,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        liquidity: u128,
        clock: &Clock,
        versioned: &Versioned,
        ctx: &mut TxContext
    ): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
        let (coin_a, coin_b) = position_manager::decrease_liquidity_with_return_(
            clmm_pool,
            clmm_positions,
            nft,
            liquidity,
            0,
            0,
            clock::timestamp_ms(clock) - 60000,
            clock,
            versioned,
            ctx,
        );

        (coin_a, coin_b)
    }

    fun collect_clmm_fees<CoinTypeA, CoinTypeB, FeeType>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let vault_id = object::id(vault);
        if (is_clmm_base_nft_exists(vault_manager, vault_id)) {
            collect_clmm_base_fees(
                vault_manager,
                vault,
                clmm_pool,
                clmm_positions,
                clock,
                clmm_versioned,
                ctx,
            );
        };
        if (is_clmm_limit_nft_exists(vault_manager, vault_id)) {
            collect_clmm_limit_fees(
                vault_manager,
                vault,
                clmm_pool,
                clmm_positions,
                clock,
                clmm_versioned,
                ctx,
            );
        };
    }

    fun collect_clmm_base_fees<CoinTypeA, CoinTypeB, FeeType>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let vault_id = object::id(vault);
        let nft = borrow_mut_clmm_base_nft(vault_manager, vault_id);
        let (coin_a, coin_b) = position_manager::collect_with_return_(
            clmm_pool,
            clmm_positions,
            nft,
            MAX_U64,
            MAX_U64,
            object::id_address(vault),
            clock::timestamp_ms(clock) - 60000,
            clock,
            clmm_versioned,
            ctx,
        );
        increase_vault_balance(
            vault_manager, 
            vault,
            coin::into_balance(coin_a),
            coin::into_balance(coin_b),
        )
        //todo Protocol fees
    }

    public fun collect_clmm_reward_direct<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Coin<RewardCoin> {
        config::checked_package_version(global_config);
        let vault_id = object::id(vault);
        collect_clmm_reward(
            global_config,
            vault_manager,
            vault,
            clmm_pool,
            clmm_positions,
            clmm_reward_vault,
            clmm_reward_index,
            recipient,
            clock,
            clmm_versioned,
            ctx, 
        );
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        let reward_type_name = type_name::get<RewardCoin>();
        
        coin::from_balance(bag::remove<TypeName, Balance<RewardCoin>>(&mut account.reward_balances, reward_type_name), ctx)
    }

    public fun collect_clmm_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        global_config: &GlobalConfig,
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        let reward_balance = balance::zero();
        let vault_id = object::id(vault);
        if (is_clmm_base_nft_exists(vault_manager, vault_id)) {
            let base_reward_coin = collect_clmm_base_reward(
                vault_manager,
                vault,
                clmm_pool,
                clmm_positions,
                clmm_reward_vault,
                clmm_reward_index,
                recipient,
                clock,
                clmm_versioned,
                ctx,
            );
            balance::join(&mut reward_balance, coin::into_balance(base_reward_coin));
        };

        if (is_clmm_limit_nft_exists(vault_manager, vault_id)) {
            let limit_reward_coin = collect_clmm_limit_reward(
                vault_manager,
                vault,
                clmm_pool,
                clmm_positions,
                clmm_reward_vault,
                clmm_reward_index,
                recipient,
                clock,
                clmm_versioned,
                ctx,
            );
            balance::join(&mut reward_balance, coin::into_balance(limit_reward_coin));
        };
        
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        let reward_type_name = type_name::get<RewardCoin>();
        if (!bag::contains<TypeName>(&account.reward_balances, reward_type_name)) {
            let zero_balance = balance::zero<RewardCoin>();
            bag::add<TypeName, Balance<RewardCoin>>(&mut account.reward_balances, reward_type_name, zero_balance);
        };

        balance::join<RewardCoin>(bag::borrow_mut<TypeName, Balance<RewardCoin>>(&mut account.reward_balances, reward_type_name), reward_balance);
    }

    fun collect_clmm_base_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Coin<RewardCoin> {
        let vault_id = object::id(vault);
        let nft = borrow_mut_clmm_base_nft(vault_manager, vault_id);
        let (reward_coin) = position_manager::collect_reward_with_return_<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
            clmm_pool,
            clmm_positions,
            nft,
            clmm_reward_vault,
            clmm_reward_index,
            MAX_U64,
            recipient,
            clock::timestamp_ms(clock) - 60000,
            clock,
            clmm_versioned,
            ctx,
        );
    
        reward_coin
    }

    fun collect_clmm_limit_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Coin<RewardCoin> {
        let vault_id = object::id(vault);
        let nft = borrow_mut_clmm_limit_nft(vault_manager, vault_id);
        let (reward_coin) = position_manager::collect_reward_with_return_<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
            clmm_pool,
            clmm_positions,
            nft,
            clmm_reward_vault,
            clmm_reward_index,
            MAX_U64,
            recipient,
            clock::timestamp_ms(clock) - 60000,
            clock,
            clmm_versioned,
            ctx,
        );
    
        reward_coin
    }

    fun collect_clmm_limit_fees<CoinTypeA, CoinTypeB, FeeType>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let vault_id = object::id(vault);
        let nft = borrow_mut_clmm_limit_nft(vault_manager, vault_id);
        let (coin_a, coin_b) = position_manager::collect_with_return_(
            clmm_pool,
            clmm_positions,
            nft,
            MAX_U64,
            MAX_U64,
            object::id_address(vault),
            clock::timestamp_ms(clock) - 60000,
            clock,
            clmm_versioned,
            ctx,
        );
        increase_vault_balance(
            vault_manager, 
            vault,
            coin::into_balance(coin_a),
            coin::into_balance(coin_b),
        )
        //todo Protocol fees
    }

    fun  increase_vault_balance<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault: &Vault,
        balance_a: Balance<CoinTypeA>,
        balance_b: Balance<CoinTypeB>,
    ) {
        let account = borrow_mut_account_balance(vault_manager, object::id(vault));
        balance::join(&mut account.coin_a_balance, balance_a);
        balance::join(&mut account.coin_b_balance, balance_b);
    }

    fun decrease_vault_balance<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
        quantity_a: u64,
        quantity_b: u64,
    ): ( Balance<CoinTypeA>, Balance<CoinTypeB> ) {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        let balance_a = balance::split(&mut account.coin_a_balance, quantity_a);
        let balance_b = balance::split(&mut account.coin_b_balance, quantity_b);

        (balance_a, balance_b)
    }

    public fun is_clmm_base_nft_exists<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): bool {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::is_some(&account.clmm_base_nft)
    }

    public fun is_clmm_limit_nft_exists<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): bool {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::is_some(&account.clmm_limit_nft)
    }

    fun fill_clmm_base_nft<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
        nft: TurbosPositionNFT,
    ) {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::fill(&mut account.clmm_base_nft, nft)
    }

    fun extract_clmm_base_nft<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): TurbosPositionNFT {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::extract(&mut account.clmm_base_nft)
    }

    fun borrow_mut_clmm_base_nft<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): &mut TurbosPositionNFT {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::borrow_mut(&mut account.clmm_base_nft)
    }

    fun fill_clmm_limit_nft<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
        nft: TurbosPositionNFT,
    ) {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::fill(&mut account.clmm_limit_nft, nft)
    }

    fun extract_clmm_limit_nft<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): TurbosPositionNFT {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::extract(&mut account.clmm_limit_nft)
    }

    fun borrow_mut_clmm_limit_nft<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): &mut TurbosPositionNFT {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        option::borrow_mut(&mut account.clmm_limit_nft)
    }

    fun  burn_clmm_base_nft<CoinTypeA, CoinTypeB, FeeType>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
        clmm_positions: &mut Positions,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let nft = extract_clmm_base_nft(vault_manager, vault_id);
        position_manager::burn<CoinTypeA, CoinTypeB, FeeType>(
            clmm_positions,
            nft,
            clmm_versioned,
            ctx,
        );
    }

    fun  burn_clmm_limit_nft<CoinTypeA, CoinTypeB, FeeType>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
        clmm_positions: &mut Positions,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let nft = extract_clmm_limit_nft(vault_manager, vault_id);
        position_manager::burn<CoinTypeA, CoinTypeB, FeeType>(
            clmm_positions,
            nft,
            clmm_versioned,
            ctx,
        );
    }

    fun withdraw_vault_balance<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): ( Balance<CoinTypeA>, Balance<CoinTypeB> ) {
        let account = borrow_mut_account_balance(vault_manager, vault_id);
        let balance_a = balance::withdraw_all(&mut account.coin_a_balance);
        let balance_b = balance::withdraw_all(&mut account.coin_b_balance);

        (balance_a, balance_b)
    }

    public fun vault_balance<CoinTypeA, CoinTypeB>(
        vault_manager: &VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): (u64, u64) {
        let amount_a = balance::value(&table::borrow(&vault_manager.accounts, vault_id).coin_a_balance);
        let amount_b = balance::value(&table::borrow(&vault_manager.accounts, vault_id).coin_b_balance);
        (amount_a, amount_b)
    }

    fun  borrow_mut_account_balance<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
    ): &mut Account<CoinTypeA, CoinTypeB> {
        table::borrow_mut(&mut vault_manager.accounts, vault_id)
    }

    fun  init_account_balance<CoinTypeA, CoinTypeB>(
        vault_manager: &mut VaultManager<CoinTypeA, CoinTypeB>,
        vault_id: ID,
        ctx: &mut TxContext,
    ) {
        table::add(
            &mut vault_manager.accounts,
            vault_id,
            Account { 
                coin_a_balance: balance::zero(), 
                coin_b_balance: balance::zero(),
                clmm_base_nft: option::none<TurbosPositionNFT>(),
                clmm_limit_nft: option::none<TurbosPositionNFT>(),
                reward_balances: bag::new(ctx),
            }
        );
    }

    fun coin_to_vec<T>(coin: Coin<T>): vector<Coin<T>> {
        let self = vector::empty<Coin<T>>();
        vector::push_back(&mut self, coin);
        self
    }
}