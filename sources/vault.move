// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::vault {
    use std::vector;
    use sui::transfer;
    use sui::display;
    use sui::package;
    use sui::event;
    use sui::vec_map::{Self, VecMap};
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
    use turbos_clmm::math_liquidity;
    use turbos_clmm::math_tick;
    use turbos_clmm::math_u128;
    use turbos_clmm::full_math_u128;
    use turbos_clmm::full_math_u64;
    use turbos_clmm::full_math_u32;
    use sui::clock::{Self, Clock};
    use turbos_assets_manage::config::{Self, GlobalConfig, OperatorCap};
    use turbos_assets_manage::rewarder::{Self, RewarderManager};


    friend turbos_assets_manage::router;
    friend turbos_assets_manage::reward_tests;

    const FEE_RATE_SCALE: u64 = 1000000;
    const MAX_U64: u64 = 0xffffffffffffffff;
    const CLMM_DEADLINE_MS: u64 = 60000;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidAmount: u64 = 1;
    const EInvalidPercentage: u64 = 2;
    const ERewardAlreadyExists: u64 = 3;
    const EInvalidTickRange: u64 = 4;
    const ETooLargeProtocolFee: u64 = 5;
    const ENotRewardCoinType: u64 = 6;
    const EBaseNftExists: u64 = 7;
    const ELimitNftExists: u64 = 8;
    const ECoinABalanceGtZero: u64 = 9;
    const ECoinBBalanceGtZero: u64 = 10;
    const ENotValidProtocolAsset: u64 = 11;
    const ENotEnoughProtocolAsset: u64 = 12;
    const ETickRangeTooSmall: u64 = 14;
    const EStrategyLocked: u64 = 15;
    const ENotValidRewarderType: u64 = 16;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<

    struct VAULT has drop {}

    struct Account has store {
        clmm_base_nft: Option<TurbosPositionNFT>,
        clmm_limit_nft: Option<TurbosPositionNFT>,
        // After rebalancing, the rewards that users have in clmm will be collected to this bag
        // and then the old NFT will be destroyed.
        balances: Bag,
    }

    struct Strategy has key, store {
        id: UID,
        clmm_pool_id: ID,
        effective_tick_lower: I32,
	    effective_tick_upper: I32,
        total_share: u128,
        rewarders: vector<TypeName>,
        coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
        fee_type_name: TypeName,
         // The key is vault's vault id.
        vaults: LinkedTable<ID, VaultInfo>,
        vault_index: u64,
        // Map from vault id -> vault account.
        accounts: Table<ID, Account>,
        // Map from user address -> vault id.
        // user_vaults: Table<address, u64>,
        protocol_fee_rate: u64,
        protocol_fees: Bag,
        image_url: String,
        tick_spacing: u32,
        default_base_rebalance_percentage: u32,
        default_limit_rebalance_percentage: u32,
        // The minimum step for the base/limit position, 1 step = 1 tick_spacing.
        base_tick_step_minimum: u32,
        limit_tick_step_minimum: u32,
        status: u8, //0: normal, 1: lock
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

    struct VaultRewardInfo has copy, drop, store {
	    reward: u128,
	    reward_debt: u128,
	    reward_harvested: u128
    }

    struct VaultInfo has copy, drop, store {
        vault_id: ID,
        strategy_id: ID,
        coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
        base_clmm_position_id: ID,
        base_lower_index: I32,
        base_upper_index: I32,
        base_liquidity: u128,
        limit_clmm_position_id: ID,
        limit_lower_index: I32,
        limit_upper_index: I32,
        limit_liquidity: u128,
        sqrt_price: u128,
        base_last_tick_index: I32,
        limit_last_tick_index: I32,
        base_rebalance_threshold: u32,
        limit_rebalance_threshold: u32,
        base_tick_step: u32,
        limit_tick_step: u32,
        share: u128,
        rewards: VecMap<TypeName, VaultRewardInfo>,
        earn_stats: VecMap<String, u128>,
    }

    struct CheckRebalance has copy, drop {
        vault_id: ID,
        rebalance: bool,
        base_lower_index: I32,
        base_upper_index: I32,
        base_just_increase: bool,
        limit_lower_index: I32,
        limit_upper_index: I32,
    }

    struct CreateStrategyEvent has copy, drop {
        strategy_id: ID,
        clmm_pool_id: ID,
        effective_tick_lower: I32,
        effective_tick_upper: I32,
        coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
        fee_type_name: TypeName,
    }

    struct OpenVaultEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
        clmm_pool_id: ID,
    }

    struct CloseVaultEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
    }

    struct DepositEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
        clmm_pool_id: ID,
        amount_a: u64,
	    amount_b: u64,
    }

    struct WithdrawEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
        clmm_pool_id: ID,
        percentage: u64,
        burn_clmm_nft: bool,
        amount_a: u64,
	    amount_b: u64,
	    protocol_fee_a_amount: u64,
	    protocol_fee_b_amount: u64
    }

    struct RebalanceEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
        clmm_pool_id: ID,
        checkRebalance: CheckRebalance,
        sqrt_price: u128,
    }

    struct AddRewardEvent has copy, drop {
        strategy_id: ID,
        clmm_pool_id: ID,
        rewarder_type: TypeName,
        allocate_point: u64
    }

    struct UpdateFeeRateEvent has copy, drop {
        strategy_id: ID,
        old_rate: u64,
        new_rate: u64,
    }

    struct ClmmRewardClaimedEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
        clmm_pool_id: ID,
        clmm_nft_id: ID,
        amount: u64,
        reward_type_name: TypeName,
    }

    struct ClmmFeeClaimedEvent has copy, drop {
        vault_id: ID,
        strategy_id: ID,
        clmm_pool_id: ID,
        clmm_nft_id: ID,
	    amount_a: u64,
	    amount_b: u64,
        coin_a_type_name: TypeName,
	    coin_b_type_name: TypeName,
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
        vector::push_back(&mut display_values, utf8(b"{image_url}"));
        vector::push_back(&mut display_values, utf8(b"https://turbos.finance"));
        vector::push_back(&mut display_values, utf8(b"Turbos Team"));

        let publisher = package::claim(vault, ctx);
        let display = display::new<Vault>(&publisher, ctx);

        display::add_multiple<Vault>(&mut display, display_keys, display_values);
        display::update_version<Vault>(&mut display);

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(display, tx_context::sender(ctx));
    }

    public(friend) fun create_strategy<CoinTypeA, CoinTypeB, FeeType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        clmm_pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
        effective_tick_lower_u32: u32,
        effective_tick_lower_is_neg: bool,
        effective_tick_upper_u32: u32,
        effective_tick_upper_is_neg: bool,
        image_url: String,
        default_base_rebalance_percentage: u32,
        default_limit_rebalance_percentage: u32,
        base_tick_step_minimum: u32,
        limit_tick_step_minimum: u32,
        ctx: &mut TxContext
    ): Strategy {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        let effective_tick_lower = i32::from_u32_neg(effective_tick_lower_u32, effective_tick_lower_is_neg);
        let effective_tick_upper = i32::from_u32_neg(effective_tick_upper_u32, effective_tick_upper_is_neg);
        let clmm_pool_id = object::id(clmm_pool);
        let coin_a_type_name = type_name::get<CoinTypeA>();
        let coin_b_type_name = type_name::get<CoinTypeB>();
        let fee_type_name = type_name::get<FeeType>();
        let vaults = linked_table::new<ID, VaultInfo>(ctx);
        let tick_spacing = pool::get_pool_tick_spacing(clmm_pool);
        let strategy = Strategy {
            id: object::new(ctx),
            clmm_pool_id,
            effective_tick_lower,
            effective_tick_upper,
            rewarders: vector::empty<TypeName>(),
            total_share: 0,
            coin_a_type_name,
            coin_b_type_name,
            fee_type_name,
            vaults,
            vault_index: 0,
            accounts: table::new(ctx),
            protocol_fee_rate: 0,
            protocol_fees: bag::new(ctx),
            image_url,
            tick_spacing,
            default_base_rebalance_percentage,
            default_limit_rebalance_percentage,
            base_tick_step_minimum,
            limit_tick_step_minimum,
            status: 0,
        };

        let strategy_id = object::id(&strategy);
        rewarder::register_strategy(rewarder_manager, strategy_id);
        
        let event = CreateStrategyEvent {
            strategy_id,
            clmm_pool_id,
            effective_tick_lower,
            effective_tick_upper,
            coin_a_type_name,
            coin_b_type_name,
            fee_type_name,
        };
        event::emit<CreateStrategyEvent>(event);

        strategy
    }

    public fun add_rewarder<RewardCoinType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
        allocate_point: u64,
        clock: &Clock,
    ) {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        // Ensure the rewarder type is not already associated with the pool.
        let rewarder_type_name = type_name::get<RewardCoinType>();
        assert!(!vector::contains(&strategy.rewarders, &rewarder_type_name), ERewardAlreadyExists);

        // Add the pool to the rewarder manager with specified allocation points.
        let strategy_id = object::id(strategy);
        rewarder::add_strategy<RewardCoinType>(rewarder_manager, strategy_id, allocate_point, clock);

        // Update the pool's rewarders list to include the new rewarder type.
        vector::push_back(&mut strategy.rewarders, rewarder_type_name);

        let event = AddRewardEvent {
            strategy_id,
            clmm_pool_id: strategy.clmm_pool_id,
            rewarder_type: rewarder_type_name,
            allocate_point,
        };
        event::emit<AddRewardEvent>(event);
    }

    public fun open_vault<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        clmm_pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
        base_tick_lower_index_u32: u32,
        base_tick_lower_index_is_neg: bool,
        base_tick_upper_index_u32: u32,
        base_tick_upper_index_is_neg: bool,
        limit_tick_lower_index_u32: u32,
        limit_tick_lower_index_is_neg: bool,
        limit_tick_upper_index_u32: u32,
        limit_tick_upper_index_is_neg: bool,
        base_tick_step: u32,
        limit_tick_step: u32,
        ctx: &mut TxContext
    ): Vault {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);
        assert!(base_tick_step >= strategy.base_tick_step_minimum && limit_tick_step >= strategy.limit_tick_step_minimum, ETickRangeTooSmall);
        
        let base_lower_index = i32::from_u32_neg(base_tick_lower_index_u32, base_tick_lower_index_is_neg);
        let base_upper_index = i32::from_u32_neg(base_tick_upper_index_u32, base_tick_upper_index_is_neg);
        let limit_lower_index = i32::from_u32_neg(limit_tick_lower_index_u32, limit_tick_lower_index_is_neg);
        let limit_upper_index = i32::from_u32_neg(limit_tick_upper_index_u32, limit_tick_upper_index_is_neg);
        let current_tick_index = pool::get_pool_current_index(clmm_pool);

        check_tick_range(
            strategy.base_tick_step_minimum,
            current_tick_index,
            base_lower_index,
            base_upper_index,
            strategy.tick_spacing,
        );

        check_tick_range(
            strategy.limit_tick_step_minimum,
            current_tick_index,
            limit_lower_index,
            limit_upper_index,
            strategy.tick_spacing,
        );

        let vault_id = object::new(ctx);
        let coin_a_type_name = type_name::get<CoinTypeA>();
        let coin_b_type_name = type_name::get<CoinTypeB>();
        let new_vault_index = strategy.vault_index + 1;
        let strategy_id = object::id(strategy);

        let vault = Vault {
            id: vault_id,
            index: new_vault_index,
            strategy_id,
            coin_a_type_name,
            coin_b_type_name,
            name: string::utf8(b"Turbos Vault's NFT"),
            description: string::utf8(b"Turbos Vault's NFT"),
            url: strategy.image_url,
        };

        init_account_balance(strategy, object::id(&vault), ctx);

        let vault_id = object::id(&vault);
        let vault_info = VaultInfo {
            vault_id,
            strategy_id,
            coin_a_type_name,
            coin_b_type_name,
            base_clmm_position_id: object::id_from_address(@0x0),
            base_liquidity: 0,
            base_lower_index: base_lower_index,
            base_upper_index: base_upper_index,
            limit_clmm_position_id: object::id_from_address(@0x0),
            limit_lower_index: limit_lower_index,
            limit_upper_index: limit_upper_index,
            limit_liquidity: 0,
            sqrt_price: 0,
            base_last_tick_index: i32::zero(),
            limit_last_tick_index: i32::zero(),
            //0~100, When the tick deviates left or right by more than this percentage, trigger rebalance, usually 75% to 80%.
            base_rebalance_threshold: strategy.default_base_rebalance_percentage,
            limit_rebalance_threshold: strategy.default_limit_rebalance_percentage,
            base_tick_step,
            limit_tick_step,
            share: 0,
            rewards: vec_map::empty<TypeName, VaultRewardInfo>(),
            earn_stats: vec_map::empty<String, u128>(),
        };
        linked_table::push_back<ID, VaultInfo>(&mut strategy.vaults, vault_id, vault_info);
        strategy.vault_index = new_vault_index;

        event::emit(OpenVaultEvent {
            vault_id,
            strategy_id,
            clmm_pool_id: strategy.clmm_pool_id,
        });

        vault
    }

    public fun deposit<CoinTypeA, CoinTypeB, FeeType>(
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
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);
        let sender = tx_context::sender(ctx);
        let vault_id = object::id(vault);
        let (amount_a_deposit, amount_b_deposit) = (coin::value(&coin_a), coin::value(&coin_b));
        assert!(amount_a_deposit > 0 || amount_b_deposit > 0, EInvalidAmount);
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_a));
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_b));

        let sqrt_price = pool::get_pool_sqrt_price(clmm_pool);
        let current_tick_index = pool::get_pool_current_index(clmm_pool);
        let base_lower_index = get_vault_base_lower_index(strategy, vault_id);
        let base_upper_index = get_vault_base_upper_index(strategy, vault_id);
        let base_clmm_position_id = get_vault_base_clmm_position_id(strategy, vault_id);
        let base_liquidity = get_vault_base_liquidity(strategy, vault_id);
        let base_last_tick_index = get_vault_base_last_tick_index(strategy, vault_id);
        if (is_clmm_base_nft_exists(strategy, vault_id)) {
            let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
            let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
            let liquidity = calculate_liquidity(sqrt_price, base_lower_index, base_upper_index, amount_a, amount_b);
            if (liquidity > 0) {
                let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
                let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
                let (base_coin_a_left, base_coin_b_left);
                (base_coin_a_left, base_coin_b_left, base_lower_index, base_upper_index, base_liquidity) = increase_clmm_liquidity(
                    strategy,
                    vault_id,
                    true,
                    clmm_pool,
                    clmm_positions,
                    coin_a,
                    coin_b,
                    clock,
                    clmm_versioned,
                    ctx,
                );

                merge_vault_balance(strategy, vault_id, coin::into_balance(base_coin_a_left));
                merge_vault_balance(strategy, vault_id, coin::into_balance(base_coin_b_left));
            };  
        } else {
            let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
            let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
            let liquidity = calculate_liquidity(sqrt_price, base_lower_index, base_upper_index, amount_a, amount_b);
            if (liquidity > 0) {
                let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
                let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
                let (nft, base_coin_a_left, base_coin_b_left) = mint_clmm_liquidity(
                    clmm_pool,
                    clmm_positions,
                    coin_a,
                    coin_b,
                    base_lower_index,
                    base_upper_index,
                    clock,
                    clmm_versioned,
                    ctx,
                );
                merge_vault_balance(strategy, vault_id, coin::into_balance(base_coin_a_left));
                merge_vault_balance(strategy, vault_id, coin::into_balance(base_coin_b_left));

                (base_lower_index, base_upper_index, base_liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(&nft));
                base_clmm_position_id = position_nft::position_id(&nft);
                fill_clmm_base_nft(strategy, vault_id, nft);
            };
            base_last_tick_index = current_tick_index;
        };
       
        let limit_lower_index = get_vault_limit_lower_index(strategy, vault_id);
        let limit_upper_index = get_vault_limit_upper_index(strategy, vault_id);
        let limit_clmm_position_id = get_vault_limit_clmm_position_id(strategy, vault_id);
        let limit_liquidity = get_vault_limit_liquidity(strategy, vault_id);
        let limit_last_tick_index = get_vault_limit_last_tick_index(strategy, vault_id);
        let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
        let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
        if (is_clmm_limit_nft_exists(strategy, vault_id)) {
            let liquidity = calculate_liquidity(sqrt_price, limit_lower_index, limit_upper_index, amount_a, amount_b);
            if (liquidity > 0) {
                let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
                let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
                let (limit_coin_a_left, limit_coin_b_left);
                (limit_coin_a_left, limit_coin_b_left, limit_lower_index, limit_upper_index , limit_liquidity) = increase_clmm_liquidity(
                    strategy,
                    vault_id,
                    false,
                    clmm_pool,
                    clmm_positions,
                    coin_a,
                    coin_b,
                    clock,
                    clmm_versioned,
                    ctx,
                );
                merge_vault_balance(strategy, vault_id, coin::into_balance(limit_coin_a_left));
                merge_vault_balance(strategy, vault_id, coin::into_balance(limit_coin_b_left));
            }; 
        };
        
        update_vault_info_with_tick_range(
            strategy,
            vault_id,
            base_clmm_position_id,
            base_lower_index,
            base_upper_index,
            base_liquidity,
            limit_clmm_position_id,
            limit_lower_index,
            limit_upper_index,
            limit_liquidity,
            sqrt_price,
            base_last_tick_index,
            limit_last_tick_index,
        );

        update_strategy_reward_info(
            rewarder_manager,
            strategy,
            vault_id,
            clock
        );

        event::emit(DepositEvent {
            vault_id,
            strategy_id: object::id(strategy),
            clmm_pool_id: object::id(clmm_pool),
            amount_a: amount_a_deposit,
            amount_b: amount_b_deposit,
        });
    }

    
    public fun withdraw<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
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
        assert!(strategy.status == 0, EStrategyLocked);
        assert!(percentage > 0 && percentage <= 100, EInvalidPercentage);

        let sqrt_price = pool::get_pool_sqrt_price(clmm_pool);
        let vault_id = object::id(vault);
        collect_clmm_fees(
            strategy,
            vault_id,
            clmm_pool,
            clmm_positions,
            clock,
            clmm_versioned,
            ctx,
        );
        let nft = borrow_mut_clmm_base_nft(strategy, vault_id);
        let (_, _, liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(nft));
        let base_liquidity = 0;
        let coin_a_out = coin::zero<CoinTypeA>(ctx);
        let coin_b_out = coin::zero<CoinTypeB>(ctx);
        if (liquidity > 0) {
            let (base_coin_a, base_coin_b) = decrease_clmm_liquidity(
                nft,
                clmm_pool,
                clmm_positions,
                full_math_u128::mul_div_floor(liquidity, (percentage as u128), 100),
                clock,
                clmm_versioned,
                ctx,
            );
            let (base_lower_index, base_upper_index, base_liquidity_new) = position_manager::get_position_info(clmm_positions, object::id_address(nft));
            base_liquidity = base_liquidity_new;
            coin::join(&mut coin_a_out, base_coin_a);
            coin::join(&mut coin_b_out, base_coin_b);
        };

        let limit_liquidity = 0;
        let is_clmm_limit_nft_exists = is_clmm_limit_nft_exists(strategy, vault_id);
        if (is_clmm_limit_nft_exists) {
            let limit_nft = borrow_mut_clmm_limit_nft(strategy, vault_id);
            let (_, _, liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(limit_nft));
            if (liquidity > 0) {
                let (limit_coin_a, limit_coin_b) = decrease_clmm_liquidity(
                    limit_nft,
                    clmm_pool,
                    clmm_positions,
                    full_math_u128::mul_div_floor(liquidity, (percentage as u128), 100),
                    clock,
                    clmm_versioned,
                    ctx,
                );
                let (limit_lower_index, limit_upper_index, limit_liquidity_new) = position_manager::get_position_info(clmm_positions, object::id_address(limit_nft));
                limit_liquidity = limit_liquidity_new;
                coin::join(&mut coin_a_out, limit_coin_a);
                coin::join(&mut coin_b_out, limit_coin_b);
            };
        };
       
        let amount_a =  vault_balance_amount<CoinTypeA>(strategy, vault_id);
        let amount_b =  vault_balance_amount<CoinTypeB>(strategy, vault_id);
        let balance_a = take_vault_balance_by_amount<CoinTypeA>(strategy, vault_id, full_math_u64::mul_div_floor(amount_a, percentage, 100));
        let balance_b = take_vault_balance_by_amount<CoinTypeB>(strategy, vault_id, full_math_u64::mul_div_floor(amount_b, percentage, 100));
        coin::join(&mut coin_a_out, coin::from_balance(balance_a, ctx));
        coin::join(&mut coin_b_out, coin::from_balance(balance_b, ctx));
        
        //protocol fee
        let protocol_fee_rate = strategy.protocol_fee_rate;
        let (protocol_fee_a, protocol_fee_b) = if (protocol_fee_rate == 0) {
            (0, 0)
        } else {
            let fee_a_amount = full_math_u64::mul_div_ceil(coin::value(&coin_a_out), protocol_fee_rate, FEE_RATE_SCALE);
            let fee_b_amount = full_math_u64::mul_div_ceil(coin::value(&coin_b_out), protocol_fee_rate, FEE_RATE_SCALE);

            let protocol_asset_a = coin::split(&mut coin_a_out, fee_a_amount, ctx);
            let protocol_asset_b = coin::split(&mut coin_b_out, fee_b_amount, ctx);

            merge_protocol_asset(strategy, coin::into_balance(protocol_asset_a));
            merge_protocol_asset(strategy, coin::into_balance(protocol_asset_b));

            (fee_a_amount, fee_b_amount)
        };
        
        if (burn_clmm_nft && percentage == 100) {
            burn_clmm_base_nft<CoinTypeA, CoinTypeB, FeeType>(
                strategy,
                vault_id,
                clmm_positions,
                clmm_versioned,
                ctx
            );
            if (is_clmm_limit_nft_exists) {
                burn_clmm_limit_nft<CoinTypeA, CoinTypeB, FeeType>(
                    strategy,
                    vault_id,
                    clmm_positions,
                    clmm_versioned,
                    ctx
                );
            }
        };

        update_vault_info(
            strategy,
            vault_id,
            base_liquidity,
            limit_liquidity,
            sqrt_price,
        );

        update_strategy_reward_info(
            rewarder_manager,
            strategy,
            vault_id,
            clock
        );

        let vault_info = borrow_vault_info(strategy, vault_id);
        event::emit(WithdrawEvent {
            vault_id,
            strategy_id: object::id(strategy),
            clmm_pool_id: object::id(clmm_pool),
            percentage,
            burn_clmm_nft,
            amount_a: coin::value(&coin_a_out),
            amount_b: coin::value(&coin_b_out),
            protocol_fee_a_amount: protocol_fee_a,
            protocol_fee_b_amount: protocol_fee_b,
        });

        (coin_a_out, coin_b_out)
    }

    public fun close_vault<CoinTypeA, CoinTypeB>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault: Vault,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);

        let vault_id = object::id(&vault);
        let account = borrow_vault_account(strategy, vault_id);
        assert!(!is_clmm_base_nft_exists(strategy, vault_id), EBaseNftExists);
        assert!(!is_clmm_limit_nft_exists(strategy, vault_id), ELimitNftExists);
        assert!(get_vault_balance<CoinTypeA>(strategy, vault_id) == 0, ECoinABalanceGtZero);
        assert!(get_vault_balance<CoinTypeB>(strategy, vault_id) == 0, ECoinBBalanceGtZero);
        remove_vault_info(strategy, vault_id);
        let Vault { 
            id, 
            index: _, 
            strategy_id: _, 
            coin_a_type_name: _, 
            coin_b_type_name: _, 
            name: _,
            description: _,
            url: _,
        } = vault;
        object::delete(id);

        event::emit(CloseVaultEvent {
            vault_id,
            strategy_id: object::id(strategy)
        })
    }

    public fun check_rebalance_loop<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        current_vault_id: ID,
        limit: u64,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        ctx: &mut TxContext
    ): (vector<CheckRebalance>, Option<ID>) {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);

        let rebalance_vaults = vector::empty();
        let index = 0;
        let last_vault_id;
        let vault_id_option = &option::some(current_vault_id);
        while(!option::is_none(vault_id_option) && index < limit) {
            let vault_id = *option::borrow(vault_id_option);
            let checkRebalance = check_rebalance(
                global_config,
                strategy,
                vault_id,
                clmm_pool,
                ctx,
            );
            if (checkRebalance.rebalance) {
                vector::push_back(&mut rebalance_vaults, checkRebalance);
            };
            last_vault_id = vault_id;
            vault_id_option = linked_table::next(&strategy.vaults, vault_id);
            index = index + 1;
        };
        (rebalance_vaults, *vault_id_option)
    }

    public fun check_rebalance<CoinTypeA, CoinTypeB, FeeType>(
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        ctx: &mut TxContext
    ): CheckRebalance {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);

        let rebalance = false;
        let vault_info = borrow_vault_info(strategy, vault_id);
        let current_tick_index = pool::get_pool_current_index(clmm_pool);
        let base_last_tick_index = vault_info.base_last_tick_index;
        let base_just_increase = false;
        let base_lower_index = vault_info.base_lower_index;
        let base_upper_index = vault_info.base_upper_index;
        let base_tick_step = vault_info.base_tick_step;
        let limit_tick_step = vault_info.limit_tick_step;
        let base_tick_length = base_tick_step * strategy.tick_spacing;
        let limit_tick_length = limit_tick_step * strategy.tick_spacing;
        let max_base_tick_move = full_math_u32::mul_div_floor(base_tick_length, vault_info.base_rebalance_threshold, 100);
        let base_tick_move =  if (i32::gt(current_tick_index, base_last_tick_index)) {
            i32::abs_u32(i32::sub(current_tick_index, base_last_tick_index))
        } else {
            i32::abs_u32(i32::sub(base_last_tick_index, current_tick_index))
        };
        if (base_tick_move >= max_base_tick_move) {
            rebalance = true;
        };

        let limit_lower_index = vault_info.limit_lower_index;
        let limit_upper_index = vault_info.limit_upper_index;
        if (!rebalance && is_clmm_limit_nft_exists(strategy, vault_id)) {
            let limit_last_tick_index = vault_info.limit_last_tick_index;
            let max_limit_tick_move = full_math_u32::mul_div_floor(limit_tick_length, vault_info.limit_rebalance_threshold, 100);
            let limit_tick_move =  if (i32::gt(current_tick_index, limit_last_tick_index)) {
                i32::abs_u32(i32::sub(current_tick_index, limit_last_tick_index))
            } else {
                i32::abs_u32(i32::sub(limit_last_tick_index, current_tick_index))
            };
            if (limit_tick_move >= max_limit_tick_move) {
                rebalance = true;
                //The base rebalance triggered by the limit rebalance does not need to change the tick range.
                //Only increase liquidity collected from limit.
                if (is_clmm_base_nft_exists(strategy, vault_id)) {
                    base_just_increase = true;
                };
            };
        };

        if (rebalance && !base_just_increase) {
            (base_lower_index, base_upper_index) = calculate_tick_index(current_tick_index, strategy.tick_spacing, base_tick_step);
        };

        if (rebalance) {
            (limit_lower_index, limit_upper_index) = calculate_tick_index(current_tick_index, strategy.tick_spacing, limit_tick_step);
        };

        CheckRebalance {
            vault_id,
            rebalance,
            base_lower_index,
            base_upper_index,
            base_just_increase,
            limit_lower_index,
            limit_upper_index
        }
    }

    
    public fun rebalance<CoinTypeA, CoinTypeB, FeeType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
        vault_id: ID,
        rebalance: bool,
        base_just_increase: bool,
        base_tick_lower_index_u32: u32,
        base_tick_lower_index_is_neg: bool,
        base_tick_upper_index_u32: u32,
        base_tick_upper_index_is_neg: bool,
        limit_tick_lower_index_u32: u32,
        limit_tick_lower_index_is_neg: bool,
        limit_tick_upper_index_u32: u32,
        limit_tick_upper_index_is_neg: bool,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_rebalance_manager_role(global_config, operator_address);
        let base_lower_index = i32::from_u32_neg(base_tick_lower_index_u32, base_tick_lower_index_is_neg);
        let base_upper_index = i32::from_u32_neg(base_tick_upper_index_u32, base_tick_upper_index_is_neg);
        let limit_lower_index = i32::from_u32_neg(limit_tick_lower_index_u32, limit_tick_lower_index_is_neg);
        let limit_upper_index = i32::from_u32_neg(limit_tick_upper_index_u32, limit_tick_upper_index_is_neg);
        let checkRebalance = CheckRebalance {
            vault_id,
            rebalance,
            base_lower_index,
            base_upper_index,
            base_just_increase,
            limit_lower_index,
            limit_upper_index
        };

        let sqrt_price = pool::get_pool_sqrt_price(clmm_pool);
        let current_tick_index = pool::get_pool_current_index(clmm_pool);

        if (!checkRebalance.base_just_increase) {
            check_tick_range(
                strategy.base_tick_step_minimum,
                current_tick_index,
                base_lower_index,
                base_upper_index,
                strategy.tick_spacing,
            );
        };

        check_tick_range(
            strategy.limit_tick_step_minimum,
            current_tick_index,
            limit_lower_index,
            limit_upper_index,
            strategy.tick_spacing,
        );

        if (!checkRebalance.rebalance) {
            return;
        };
        collect_clmm_fees(
            strategy,
            vault_id,
            clmm_pool,
            clmm_positions,
            clock,
            clmm_versioned,
            ctx,
        );

        let base_clmm_position_id = get_vault_base_clmm_position_id(strategy, vault_id);
        let base_liquidity = get_vault_base_liquidity(strategy, vault_id);
        let limit_clmm_position_id = get_vault_limit_clmm_position_id(strategy, vault_id);
        let limit_liquidity = get_vault_limit_liquidity(strategy, vault_id);
        let base_last_tick_index = get_vault_base_last_tick_index(strategy, vault_id);
        let limit_last_tick_index = get_vault_limit_last_tick_index(strategy, vault_id);

        //burn limit position first
        if (is_clmm_limit_nft_exists(strategy, vault_id)) {
            let limit_nft = borrow_mut_clmm_limit_nft(strategy, vault_id);
            let (_, _, liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(limit_nft));
            if (liquidity > 0) {
                let (limit_coin_a, limit_coin_b) = decrease_clmm_liquidity(
                    limit_nft,
                    clmm_pool,
                    clmm_positions,
                    liquidity,
                    clock,
                    clmm_versioned,
                    ctx,
                );
                limit_liquidity = 0;
                merge_vault_balance(strategy, vault_id, coin::into_balance(limit_coin_a));
                merge_vault_balance(strategy, vault_id, coin::into_balance(limit_coin_b));
            };
            burn_clmm_limit_nft<CoinTypeA, CoinTypeB, FeeType>(
                strategy,
                vault_id,
                clmm_positions,
                clmm_versioned,
                ctx
            );
        };
        let (limit_lower_index, limit_upper_index) = (checkRebalance.limit_lower_index, checkRebalance.limit_upper_index);
        let coin_a_left = coin::zero<CoinTypeA>(ctx);
        let coin_b_left = coin::zero<CoinTypeB>(ctx);
        if (is_clmm_base_nft_exists(strategy, vault_id)) {
            if (checkRebalance.base_just_increase) {
                //just increase
                let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
                let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
                let liquidity = calculate_liquidity(sqrt_price, base_lower_index, base_upper_index, amount_a, amount_b);
                if (liquidity > 0) {
                    let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
                    let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
                    let (base_coin_a_left, base_coin_b_left);
                    (base_coin_a_left, base_coin_b_left, base_lower_index, base_upper_index, base_liquidity) = increase_clmm_liquidity(
                        strategy,
                        vault_id,
                        true,
                        clmm_pool,
                        clmm_positions,
                        coin_a,
                        coin_b,
                        clock,
                        clmm_versioned,
                        ctx,
                    );
                    coin::join(&mut coin_a_left, base_coin_a_left);
                    coin::join(&mut coin_b_left, base_coin_b_left);
                };
            } else {
                //burn current base position
                let nft = borrow_mut_clmm_base_nft(strategy, vault_id);
                let (_, _, liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(nft));
                let (base_coin_a, base_coin_b) = decrease_clmm_liquidity(
                    nft,
                    clmm_pool,
                    clmm_positions,
                    liquidity,
                    clock,
                    clmm_versioned,
                    ctx,
                );
                merge_vault_balance(strategy, vault_id, coin::into_balance(base_coin_a));
                merge_vault_balance(strategy, vault_id, coin::into_balance(base_coin_b));
                burn_clmm_base_nft<CoinTypeA, CoinTypeB, FeeType>(
                    strategy,
                    vault_id,
                    clmm_positions,
                    clmm_versioned,
                    ctx
                );
                base_liquidity = 0;
                let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
                let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
                let liquidity = calculate_liquidity(sqrt_price, checkRebalance.base_lower_index, checkRebalance.base_upper_index, amount_a, amount_b);
                if (liquidity > 0) {
                    let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
                    let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
                    let (new_nft, base_coin_a_left, base_coin_b_left) = mint_clmm_liquidity(
                        clmm_pool,
                        clmm_positions,
                        coin_a,
                        coin_b,
                        checkRebalance.base_lower_index,
                        checkRebalance.base_upper_index,
                        clock,
                        clmm_versioned,
                        ctx,
                    );

                    coin::join(&mut coin_a_left, base_coin_a_left);
                    coin::join(&mut coin_b_left, base_coin_b_left);
                    (_,_ , base_liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(&new_nft));  
                    base_clmm_position_id = position_nft::position_id(&new_nft);
                    fill_clmm_base_nft(strategy, vault_id, new_nft);
                };
                base_last_tick_index = current_tick_index;
            };
        } else {
            //The base position does not exist, and minting needs to be based on the capital situation.
            let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
            let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
            let liquidity = calculate_liquidity(sqrt_price, checkRebalance.base_lower_index, checkRebalance.base_upper_index, amount_a, amount_b);
            if (liquidity > 0) {
                let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
                let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
                let (new_nft, base_coin_a_left, base_coin_b_left) = mint_clmm_liquidity(
                    clmm_pool,
                    clmm_positions,
                    coin_a,
                    coin_b,
                    checkRebalance.base_lower_index,
                    checkRebalance.base_upper_index,
                    clock,
                    clmm_versioned,
                    ctx,
                );

                coin::join(&mut coin_a_left, base_coin_a_left);
                coin::join(&mut coin_b_left, base_coin_b_left);
                (_,_ , base_liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(&new_nft));  
                base_clmm_position_id = position_nft::position_id(&new_nft);
                fill_clmm_base_nft(strategy, vault_id, new_nft);
            };
            base_last_tick_index = current_tick_index;
        };
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_a_left));
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_b_left));

        let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
        let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
        let bid_lower_index = checkRebalance.limit_lower_index;
        let bid_upper_index = floor_tick_index(current_tick_index, strategy.tick_spacing, true);
        let ask_lower_index = floor_tick_index(current_tick_index, strategy.tick_spacing, false);
        let ask_upper_index = checkRebalance.limit_upper_index;
        let bid_liquidity = calculate_liquidity(sqrt_price, bid_lower_index, bid_upper_index, amount_a, amount_b);
        let ask_liquidity = calculate_liquidity(sqrt_price, ask_lower_index, ask_upper_index, amount_a, amount_b);
        if (bid_liquidity > 0 || ask_liquidity > 0) {
            (limit_lower_index, limit_upper_index) = if (bid_liquidity > ask_liquidity) {
                (bid_lower_index, bid_upper_index)
            } else {
                (ask_lower_index, ask_upper_index)
            };
            let coin_a = coin::from_balance(take_vault_balance<CoinTypeA>(strategy, vault_id), ctx);
            let coin_b = coin::from_balance(take_vault_balance<CoinTypeB>(strategy, vault_id), ctx);
            let (nft_limit, limit_coin_a_left, limit_coin_b_left) = mint_clmm_liquidity(
                clmm_pool,
                clmm_positions,
                coin_a,
                coin_b,
                limit_lower_index,
                limit_upper_index,
                clock,
                clmm_versioned,
                ctx,
            );
            (_,_ , limit_liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(&nft_limit));
            limit_clmm_position_id = position_nft::position_id(&nft_limit);
            fill_clmm_limit_nft(strategy, vault_id, nft_limit);

            merge_vault_balance(strategy, vault_id, coin::into_balance(limit_coin_a_left));
            merge_vault_balance(strategy, vault_id, coin::into_balance(limit_coin_b_left));
        };
        limit_last_tick_index = current_tick_index;
        
        update_vault_info_with_tick_range(
            strategy,
            vault_id,
            base_clmm_position_id,
            checkRebalance.base_lower_index,
            checkRebalance.base_upper_index,
            base_liquidity,
            limit_clmm_position_id,
            limit_lower_index,
            limit_upper_index,
            limit_liquidity,
            sqrt_price,
            base_last_tick_index,
            limit_last_tick_index,
        );

        update_strategy_reward_info(
            rewarder_manager,
            strategy,
            vault_id,
            clock
        );

        event::emit(RebalanceEvent {
            vault_id,
            strategy_id: object::id(strategy),
            clmm_pool_id: object::id(clmm_pool),
            checkRebalance: checkRebalance,
            sqrt_price,
        });
    }

    public fun calculate_tick_index(
        curent_index: I32,
        tick_spacing: u32,
        step: u32,
    ): (I32, I32) {
        // lower_index = (curent_index - (curent_index % tick_spacing)) - (step + 1) * tick_spacing
        // upper_index = (curent_index - (curent_index % tick_spacing)) + (step + 1) * tick_spacing
        let remainder = i32::sub(curent_index, i32::mod(curent_index, i32::from_u32(tick_spacing)));
        let step_i32 = i32::from_u32(step + 1);
        let lower_index = i32::sub(remainder, i32::mul(i32::from_u32(tick_spacing), step_i32));
        let upper_index = i32::add(remainder, i32::mul(i32::from_u32(tick_spacing), step_i32));

        (lower_index, upper_index)
    }

    public fun floor_tick_index(
        tick_index: I32,
        tick_spacing: u32,
        is_lower: bool,
    ): I32 {
        let tick_spacing_i32 = i32::from(tick_spacing);
        if (i32::eq(i32::mod(tick_index, tick_spacing_i32), i32::zero())) {
            return tick_index
        };
        let remainder = i32::sub(tick_index, i32::mod(tick_index, tick_spacing_i32));
        if (i32::gt(tick_index, i32::zero())) {
            if (!is_lower) {
                remainder = i32::add(remainder, tick_spacing_i32)
            }
        } else {
            if (is_lower) {
                remainder = i32::sub(remainder, tick_spacing_i32)
            }
        };

        remainder
    }

    fun calculate_liquidity(
        sqrt_price: u128,
        tick_lower: I32,
        tick_upper: I32,
        amount_a: u64,
        amount_b: u64,
    ): u128 {
        math_liquidity::get_liquidity_for_amounts(
            sqrt_price, 
            math_tick::sqrt_price_from_tick_index(tick_lower), 
            math_tick::sqrt_price_from_tick_index(tick_upper), 
            (amount_a as u128), 
            (amount_b as u128)
        )
    }

    public(friend) fun collect_protocol_fee<BalanceType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<BalanceType> {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        coin::from_balance(take_protocol_asset_by_amount<BalanceType>(strategy, amount), ctx)
    }

    fun check_tick_range(
        tick_step_minimum: u32,
        current_index: I32,
        lower_index: I32,
        upper_index: I32,
        tick_spacing: u32,
    ) {
        let tick_spacing_i32 = i32::from_u32(tick_spacing);
        assert!(i32::lt(lower_index, current_index) && i32::lt(current_index, upper_index), EInvalidTickRange);
        
        let (minimum_lower_index, minimum_upper_index) = calculate_tick_index(
            current_index,
            tick_spacing,
            //To avoid slippage
            tick_step_minimum - 1
        );

        assert!(i32::lte(
            lower_index,
            minimum_lower_index,
        ), ETickRangeTooSmall);
        assert!(i32::gte(
            upper_index,
            minimum_upper_index
        ), ETickRangeTooSmall)
    }

    fun update_vault_info(
        strategy: &mut Strategy,
        vault_id: ID,
        base_liquidity: u128,
        limit_liquidity: u128,
        sqrt_price: u128,
    ) {
        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        vault_info.base_liquidity = base_liquidity;
        vault_info.limit_liquidity = limit_liquidity;
        vault_info.sqrt_price = sqrt_price;
    }

    fun update_vault_info_with_tick_range(
        strategy: &mut Strategy,
        vault_id: ID,
        base_clmm_position_id:ID, 
        base_lower_index: I32,
        base_upper_index: I32,
        base_liquidity: u128,
        limit_clmm_position_id:ID, 
        limit_lower_index: I32,
        limit_upper_index: I32,
        limit_liquidity: u128,
        sqrt_price: u128,
        base_last_tick_index: I32,
        limit_last_tick_index: I32,
    ) {
        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        vault_info.base_clmm_position_id = base_clmm_position_id;
        vault_info.base_lower_index = base_lower_index;
        vault_info.base_upper_index = base_upper_index;
        vault_info.base_liquidity = base_liquidity;
        vault_info.limit_clmm_position_id = limit_clmm_position_id;
        vault_info.limit_lower_index = limit_lower_index;
        vault_info.limit_upper_index = limit_upper_index;
        vault_info.limit_liquidity = limit_liquidity;
        vault_info.sqrt_price = sqrt_price;
        vault_info.base_last_tick_index = base_last_tick_index;
        vault_info.limit_last_tick_index = limit_last_tick_index;
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
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            versioned,
            ctx,
        );

        (nft, coin_a_left, coin_b_left)
    }

    fun increase_clmm_liquidity<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &mut Strategy,
        vault_id: ID,
        is_base: bool,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        coin_a: Coin<CoinTypeA>, 
        coin_b: Coin<CoinTypeB>, 
        clock: &Clock,
        versioned: &Versioned,
        ctx: &mut TxContext
    ): (Coin<CoinTypeA>, Coin<CoinTypeB>, I32, I32, u128) {
        let amount_a_desired = coin::value(&coin_a);
        let amount_b_desired = coin::value(&coin_b);
        let nft = if (is_base) borrow_mut_clmm_base_nft(strategy, vault_id) else borrow_mut_clmm_limit_nft(strategy, vault_id);
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
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            versioned,
            ctx,
        );
        let (lower_index, upper_index , liquidity) = position_manager::get_position_info(clmm_positions, object::id_address(nft));

        (coin_a_left, coin_b_left, lower_index, upper_index , liquidity)
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
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            versioned,
            ctx,
        );

        (coin_a, coin_b)
    }

    fun update_strategy_reward_info(
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
        vault_id: ID,
        clock: &Clock,
    ): u128 {
        let new_share = 0;
        let strategy_id = object::id(strategy);
        let (
            base_lower_index,
            base_upper_index,
            base_liquidity,
            limit_lower_index,
            limit_upper_index,
            limit_liquidity,
            sqrt_price,
            old_share,
            rewards,
        ) = get_vault_info(strategy, vault_id);
        //If the vault_id is in the reward blacklist, it will not participate in the reward.
        if (!rewarder::is_in_black_list(rewarder_manager, object::id_to_address(&vault_id))) {
            if (is_clmm_base_nft_exists(strategy, vault_id)) {
                let share = calculate_position_share(
                    base_lower_index, 
                    base_upper_index, 
                    base_liquidity, 
                    sqrt_price, 
                    strategy.effective_tick_lower, 
                    strategy.effective_tick_upper,
                );
                new_share = new_share + share;
            };

            if (is_clmm_limit_nft_exists(strategy, vault_id)) {
                let share = calculate_position_share(
                    limit_lower_index, 
                    limit_upper_index, 
                    limit_liquidity, 
                    sqrt_price, 
                    strategy.effective_tick_lower, 
                    strategy.effective_tick_upper,
                );
                new_share = new_share + share;
            };
        };
        
        let total_share = strategy.total_share;
        let new_total_share = total_share - old_share + new_share;
        
        // get new acc_per_share of strategy
        let rewards_settled = rewarder::strategy_rewards_settle(
            rewarder_manager,
            strategy.rewarders,
            strategy_id, 
            clock,
        );

        update_vault_reward_info(
            strategy,
            vault_id,
            rewards_settled, 
            new_share,
        );
        
        strategy.total_share = new_total_share;
        
        rewarder::set_strategy_share(rewarder_manager, strategy_id, new_total_share);
        
        new_share
    }

    public fun calculate_position_share(
        tick_lower: I32, 
        tick_upper: I32,
        liquidity: u128,
        sqrt_price: u128, 
        effective_tick_lower: I32,
        effective_tick_upper: I32, 
    ): u128 {
        assert!(i32::lt(tick_lower, tick_upper), EInvalidTickRange);
        assert!(i32::lt(effective_tick_lower, effective_tick_upper), EInvalidTickRange);

        let in_range: bool;
        if (i32::lte(tick_upper, effective_tick_lower) || i32::gte(tick_lower, effective_tick_upper)) {
            in_range = false;
        } else {
            in_range = true;
        };
        if (!in_range) {
            return 0
        };

         let final_tick_lower = if (i32::lt(tick_lower, effective_tick_lower)) {
            effective_tick_lower
        } else {
            tick_lower
        };

        let final_tick_upper = if (i32::lt(tick_upper, effective_tick_upper)) {
            tick_upper
        } else {
            effective_tick_upper
        };

        let (amount0, amount1) = math_liquidity::get_amount_for_liquidity(
            sqrt_price,
            math_tick::sqrt_price_from_tick_index(final_tick_lower),
            math_tick::sqrt_price_from_tick_index(final_tick_upper),
            liquidity
        );

        let price = (sqrt_price as u256) * (sqrt_price as u256) * 1000000000 / 0xffffffffffffffffffffffffffffffffu256;
        let amount_0_in_quote_token = ((amount0 as u256) * price / 1000000000 as u128);
        
        (amount_0_in_quote_token + amount1)
    }


    fun collect_clmm_fees<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        if (is_clmm_base_nft_exists(strategy, vault_id)) {
            collect_clmm_base_fees(
                strategy,
                vault_id,
                clmm_pool,
                clmm_positions,
                clock,
                clmm_versioned,
                ctx,
            );
        };
        if (is_clmm_limit_nft_exists(strategy, vault_id)) {
            collect_clmm_limit_fees(
                strategy,
                vault_id,
                clmm_pool,
                clmm_positions,
                clock,
                clmm_versioned,
                ctx,
            );
        };
    }

    fun update_vault_reward_info_on_claim(
        strategy: &mut Strategy,
        vault_id: ID,
        rewarder_type: TypeName,
    ): u64 {
        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        let reward_info = vec_map::get_mut(&mut vault_info.rewards, &rewarder_type);
        let claimed_reward = reward_info.reward;
        reward_info.reward = 0;
        reward_info.reward_harvested = reward_info.reward_harvested + claimed_reward;

        (claimed_reward as u64)
    }

    // pending reward = (new_share * strategy.acc_per_share) - vault_info.reward_debt
    fun update_vault_reward_info(
        strategy: &mut Strategy,
        vault_id: ID,
        rewards: VecMap<TypeName, u128>,
        new_share: u128,
    ) {
        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        let size = vec_map::size(&rewards);
        let index: u64 = 0;

        while (index < size) {
            let (reward_type, acc_per_share) = vec_map::get_entry_by_idx(&rewards, index);
            let new_reward_share = (full_math_u128::full_mul(*acc_per_share, new_share) as u128);
            // reward of vault
            let reward_debt = (full_math_u128::full_mul(*acc_per_share, vault_info.share) as u128);

            if (!vec_map::contains<TypeName, VaultRewardInfo>(&vault_info.rewards, reward_type)) {
                let vault_reward_info = VaultRewardInfo {
                    reward: 0,
                    reward_debt: new_reward_share,
                    reward_harvested: 0,
                };
                vec_map::insert(&mut vault_info.rewards, *reward_type, vault_reward_info);
            } else {
                let reward_info = vec_map::get_mut(&mut vault_info.rewards, reward_type);
                reward_info.reward = reward_info.reward + new_reward_share - reward_info.reward_debt;
                reward_info.reward_debt = new_reward_share;
            };

            index = index + 1;
        };

        vault_info.share = new_share;
    }

    fun merge_vault_balance<BalanceType>(
        strategy: &mut Strategy,
        vault_id: ID,
        balance: Balance<BalanceType>,
    ) {
        let balance_value = balance::value<BalanceType>(&balance);
        let type_name = get_type_name_str<BalanceType>();

        let account = borrow_mut_vault_account(strategy, vault_id);
        if (bag::contains<String>(&account.balances, type_name)) {
            let balance_ref = bag::borrow_mut<String, Balance<BalanceType>>(&mut  account.balances, type_name);
            balance::join<BalanceType>(balance_ref, balance);
        } else {
            bag::add<String, Balance<BalanceType>>(&mut account.balances, type_name, balance);
        }
    }

    fun take_vault_balance_by_amount<BalanceType>(
        strategy: &mut Strategy,
        vault_id: ID,
        amount: u64,
    ): Balance<BalanceType> {
        let type_name = get_type_name_str<BalanceType>();

        let account = borrow_mut_vault_account(strategy, vault_id);
        let balance = if (bag::contains<String>(&account.balances, type_name)) {
            let balance_ref = bag::borrow_mut<String, Balance<BalanceType>>(&mut account.balances, type_name);
            balance::split<BalanceType>(balance_ref, amount)
        } else {
            balance::zero<BalanceType>()
        };
        
        balance
    }

    fun take_vault_balance<BalanceType>(
        strategy: &mut Strategy,
        vault_id: ID,
    ): Balance<BalanceType> {
        let type_name = get_type_name_str<BalanceType>();

        let account = borrow_mut_vault_account(strategy, vault_id);
        if (bag::contains<String>(&account.balances, type_name)) {
            bag::remove<String, Balance<BalanceType>>(&mut account.balances, type_name)
        } else {
            balance::zero<BalanceType>()
        }
    }

    public fun vault_balance_amount<BalanceType>(
        strategy: &Strategy,
        vault_id: ID,
    ): u64 {
        let type_name = get_type_name_str<BalanceType>();
        
        let account = borrow_vault_account(strategy, vault_id);
        if (bag::contains<String>(&account.balances, type_name)) {
            let balance = bag::borrow<String, Balance<BalanceType>>(&account.balances, type_name);
            balance::value(balance)
        } else {
            0
        }
    }

    fun take_protocol_asset_by_amount<BalanceType>(
        strategy: &mut Strategy,
        amount: u64,
    ): Balance<BalanceType> {
        let type_name = get_type_name_str<BalanceType>();
    
        assert!(bag::contains<String>(&strategy.protocol_fees, type_name), ENotValidProtocolAsset);
        let protocol_fees_ref = bag::borrow_mut<String, Balance<BalanceType>>(&mut strategy.protocol_fees, type_name);
        assert!(balance::value(protocol_fees_ref) >= amount, ENotEnoughProtocolAsset);

        balance::split<BalanceType>(protocol_fees_ref, amount)
    }

    fun merge_protocol_asset<BalanceType>(
        strategy: &mut Strategy,
        balance: Balance<BalanceType>,
    ) {
        let balance_value = balance::value<BalanceType>(&balance);
        let type_name = get_type_name_str<BalanceType>();

        if (bag::contains<String>(&strategy.protocol_fees, type_name)) {
            let protocol_fees_ref = bag::borrow_mut<String, Balance<BalanceType>>(&mut strategy.protocol_fees, type_name);
            balance::join<BalanceType>(protocol_fees_ref, balance);
        } else {
            bag::add<String, Balance<BalanceType>>(&mut strategy.protocol_fees, type_name, balance);
        }
    }

    fun get_type_name_str<T> (): String {
        let type_name = type_name::get<T>();
        let asset_name = string::from_ascii(type_name::into_string(type_name));

        asset_name
    }

    public fun collect_reward<RewardCoinType>(
        global_config: &GlobalConfig,
        rewarder_manager: &mut RewarderManager,
        strategy: &mut Strategy,
        vault: &Vault,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Coin<RewardCoinType> {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);

        let rewarder_type_name = type_name::get<RewardCoinType>();
        assert!(vector::contains<TypeName>(&strategy.rewarders, &rewarder_type_name), ENotValidRewarderType);
        let strategy_id = object::id(strategy);
        let vault_id = object::id(vault);
        
        let rewards_settled = rewarder::strategy_rewards_settle(
            rewarder_manager,
            strategy.rewarders,
            strategy_id, 
            clock,
        );

        let vault_info = borrow_vault_info(strategy, vault_id);
        update_vault_reward_info(
            strategy,
            vault_id,
            rewards_settled, 
            vault_info.share,
        );

        let amount = update_vault_reward_info_on_claim(
            strategy,
            vault_id,
            rewarder_type_name
        );

        let balance = rewarder::withdraw_reward(
            rewarder_manager,
            strategy_id,
            amount
        );
         coin::from_balance(balance, ctx)
    }

    public fun collect_clmm_reward_direct_return<CoinTypeA, CoinTypeB, FeeType, RewardCoinType>(
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
    ): Coin<RewardCoinType> {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);
        let vault_id = object::id(vault);
        let reward_type = type_name::get<RewardCoinType>();
        let reward_balance = collect_clmm_reward(
            strategy,
            object::id(vault),
            clmm_pool,
            clmm_positions,
            clmm_reward_vault,
            clmm_reward_index,
            recipient,
            clock,
            clmm_versioned,
            ctx, 
        );
        let account = borrow_mut_vault_account(strategy, vault_id);

        let reward_type_name = get_type_name_str<RewardCoinType>();
        // If the reward coin is not one of the two coin in the current pool, the balances in accounts need to be returned together.
        if (reward_type!=vault.coin_a_type_name && reward_type!=vault.coin_b_type_name) {
            if (bag::contains<String>(&account.balances, reward_type_name)) {
                balance::join<RewardCoinType>(&mut reward_balance, bag::remove<String, Balance<RewardCoinType>>(&mut account.balances, reward_type_name));
            };
        };
        coin::from_balance(reward_balance, ctx)
    }

    public fun collect_clmm_reward_to_vault<CoinTypeA, CoinTypeB, FeeType, RewardCoinType>(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoinType>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        config::checked_package_version(global_config);
        assert!(strategy.status == 0, EStrategyLocked);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_rebalance_manager_role(global_config, operator_address);

        let reward_balance = collect_clmm_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoinType>(
            strategy,
            vault_id,
            clmm_pool,
            clmm_positions,
            clmm_reward_vault,
            clmm_reward_index,
            recipient,
            clock,
            clmm_versioned,
            ctx,
        );

        merge_vault_balance(strategy, vault_id, reward_balance);
    }


    fun collect_clmm_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Balance<RewardCoin> {
        let reward_balance = balance::zero();
        if (is_clmm_base_nft_exists(strategy, vault_id)) {
            let base_reward_coin = collect_clmm_base_reward(
                strategy,
                vault_id,
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

        if (is_clmm_limit_nft_exists(strategy, vault_id)) {
            let limit_reward_coin = collect_clmm_limit_reward(
                strategy,
                vault_id,
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
        
        reward_balance
    }

    fun collect_clmm_base_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Coin<RewardCoin> {
        let strategy_id = object::id(strategy);
        let clmm_pool_id = object::id(clmm_pool);
        let nft = borrow_mut_clmm_base_nft(strategy, vault_id);
        let clmm_nft_id = object::id(nft);
        let (reward_coin) = position_manager::collect_reward_with_return_<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
            clmm_pool,
            clmm_positions,
            nft,
            clmm_reward_vault,
            clmm_reward_index,
            MAX_U64,
            recipient,
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            clmm_versioned,
            ctx,
        );
        let amount = coin::value(&reward_coin);
        update_earn_stats<RewardCoin>(strategy, vault_id, amount);

        event::emit(ClmmRewardClaimedEvent {
            vault_id,
            strategy_id,
            clmm_pool_id,
            clmm_nft_id,
            amount,
            reward_type_name: type_name::get<RewardCoin>(),
        });
    
        reward_coin
    }

    fun collect_clmm_limit_reward<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clmm_reward_vault: &mut PoolRewardVault<RewardCoin>,
        clmm_reward_index: u64,
        recipient: address,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ): Coin<RewardCoin> {
        let strategy_id = object::id(strategy);
        let clmm_pool_id = object::id(clmm_pool);
        let nft = borrow_mut_clmm_limit_nft(strategy, vault_id);
        let clmm_nft_id = object::id(nft);

        let (reward_coin) = position_manager::collect_reward_with_return_<CoinTypeA, CoinTypeB, FeeType, RewardCoin>(
            clmm_pool,
            clmm_positions,
            nft,
            clmm_reward_vault,
            clmm_reward_index,
            MAX_U64,
            recipient,
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            clmm_versioned,
            ctx,
        );
        let amount = coin::value(&reward_coin);
        update_earn_stats<RewardCoin>(strategy, vault_id, amount);

         event::emit(ClmmRewardClaimedEvent {
            vault_id,
            strategy_id,
            clmm_pool_id,
            clmm_nft_id,
            amount,
            reward_type_name: type_name::get<RewardCoin>(),
        });
    
        reward_coin
    }


    fun collect_clmm_base_fees<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let strategy_id = object::id(strategy);
        let clmm_pool_id = object::id(clmm_pool);
        let nft = borrow_mut_clmm_base_nft(strategy, vault_id);
        let clmm_nft_id = object::id(nft);
        let (coin_a, coin_b) = position_manager::collect_with_return_(
            clmm_pool,
            clmm_positions,
            nft,
            MAX_U64,
            MAX_U64,
            object::id_to_address(&vault_id),
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            clmm_versioned,
            ctx,
        );

        let amount_a = coin::value<CoinTypeA>(&coin_a);
        let amount_b = coin::value<CoinTypeB>(&coin_b);
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_a));
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_b));
        update_earn_stats<CoinTypeA>(strategy, vault_id, amount_a);
        update_earn_stats<CoinTypeB>(strategy, vault_id, amount_b);

        event::emit(ClmmFeeClaimedEvent {
            vault_id,
            strategy_id,
            clmm_pool_id,
            clmm_nft_id,
            amount_a,
            amount_b,
            coin_a_type_name: type_name::get<CoinTypeA>(),
            coin_b_type_name: type_name::get<CoinTypeB>(),
        })
    }


    fun collect_clmm_limit_fees<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_pool: &mut Pool<CoinTypeA, CoinTypeB, FeeType>,
        clmm_positions: &mut Positions,
        clock: &Clock,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let strategy_id = object::id(strategy);
        let clmm_pool_id = object::id(clmm_pool);
        let nft = borrow_mut_clmm_limit_nft(strategy, vault_id);
        let clmm_nft_id = object::id(nft);

        let (coin_a, coin_b) = position_manager::collect_with_return_(
            clmm_pool,
            clmm_positions,
            nft,
            MAX_U64,
            MAX_U64,
            object::id_to_address(&vault_id),
            clock::timestamp_ms(clock) + CLMM_DEADLINE_MS,
            clock,
            clmm_versioned,
            ctx,
        );
        let amount_a = coin::value<CoinTypeA>(&coin_a);
        let amount_b = coin::value<CoinTypeB>(&coin_b);
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_a));
        merge_vault_balance(strategy, vault_id, coin::into_balance(coin_b));
        update_earn_stats<CoinTypeA>(strategy, vault_id, amount_a);
        update_earn_stats<CoinTypeB>(strategy, vault_id, amount_b);

        event::emit(ClmmFeeClaimedEvent {
            vault_id,
            strategy_id,
            clmm_pool_id,
            clmm_nft_id,
            amount_a,
            amount_b,
            coin_a_type_name: type_name::get<CoinTypeA>(),
            coin_b_type_name: type_name::get<CoinTypeB>(),
        })
    }

    fun update_earn_stats<T>(
        strategy: &mut Strategy,
        vault_id: ID,
        amount: u64,
    ) {
        let type_name = get_type_name_str<T>();
        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        if (vec_map::contains(&vault_info.earn_stats, &type_name)) {
            let vaule = vec_map::get_mut(&mut vault_info.earn_stats, &type_name);
            *vaule = *vaule + (amount as u128);
        } else {
            vec_map::insert(&mut vault_info.earn_stats, type_name, (amount as u128));
        }
    }

    public fun is_clmm_base_nft_exists(
        strategy: &Strategy,
        vault_id: ID,
    ): bool {
        let account = borrow_vault_account(strategy, vault_id);
        option::is_some(&account.clmm_base_nft)
    }

    public fun is_clmm_limit_nft_exists(
        strategy: &Strategy,
        vault_id: ID,
    ): bool {
        let account = borrow_vault_account(strategy, vault_id);
        option::is_some(&account.clmm_limit_nft)
    }

    fun fill_clmm_base_nft(
        strategy: &mut Strategy,
        vault_id: ID,
        nft: TurbosPositionNFT,
    ) {
        let account = borrow_mut_vault_account(strategy, vault_id);
        option::fill(&mut account.clmm_base_nft, nft)
    }

    fun extract_clmm_base_nft(
        strategy: &mut Strategy,
        vault_id: ID,
    ): TurbosPositionNFT {
        let account = borrow_mut_vault_account(strategy, vault_id);
        option::extract(&mut account.clmm_base_nft)
    }

    fun borrow_mut_clmm_base_nft(
        strategy: &mut Strategy,
        vault_id: ID,
    ): &mut TurbosPositionNFT {
        let account = borrow_mut_vault_account(strategy, vault_id);
        option::borrow_mut(&mut account.clmm_base_nft)
    }

    fun borrow_clmm_base_nft(
        strategy: &Strategy,
        vault_id: ID,
    ): &TurbosPositionNFT {
        let account = borrow_vault_account(strategy, vault_id);
        option::borrow(&account.clmm_base_nft)
    }

    fun fill_clmm_limit_nft(
        strategy: &mut Strategy,
        vault_id: ID,
        nft: TurbosPositionNFT,
    ) {
        let account = borrow_mut_vault_account(strategy, vault_id);
        option::fill(&mut account.clmm_limit_nft, nft)
    }

    fun extract_clmm_limit_nft(
        strategy: &mut Strategy,
        vault_id: ID,
    ): TurbosPositionNFT {
        let account = borrow_mut_vault_account(strategy, vault_id);
        option::extract(&mut account.clmm_limit_nft)
    }

    fun borrow_mut_clmm_limit_nft(
        strategy: &mut Strategy,
        vault_id: ID,
    ): &mut TurbosPositionNFT {
        let account = borrow_mut_vault_account(strategy, vault_id);
        option::borrow_mut(&mut account.clmm_limit_nft)
    }

    fun borrow_clmm_limit_nft(
        strategy: &Strategy,
        vault_id: ID,
    ): &TurbosPositionNFT {
        let account = borrow_vault_account(strategy, vault_id);
        option::borrow(&account.clmm_limit_nft)
    }

    fun  burn_clmm_base_nft<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_positions: &mut Positions,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let nft = extract_clmm_base_nft(strategy, vault_id);
        position_manager::burn<CoinTypeA, CoinTypeB, FeeType>(
            clmm_positions,
            nft,
            clmm_versioned,
            ctx,
        );
    }

    fun  burn_clmm_limit_nft<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &mut Strategy,
        vault_id: ID,
        clmm_positions: &mut Positions,
        clmm_versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        let nft = extract_clmm_limit_nft(strategy, vault_id);
        position_manager::burn<CoinTypeA, CoinTypeB, FeeType>(
            clmm_positions,
            nft,
            clmm_versioned,
            ctx,
        );
    }

    public(friend) fun update_strategy_status(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        status: u8,
    ): u8 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        strategy.status = status;

        status
    }

    public(friend) fun update_strategy_image_url(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        image_url: String,
    ): String {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        strategy.image_url = image_url;

        image_url
    }

    public(friend) fun update_strategy_protocol_fee_rate(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        new_rate: u64,
    ): u64 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        assert!(new_rate <= FEE_RATE_SCALE, ETooLargeProtocolFee);
        let old_rate = strategy.protocol_fee_rate;
        strategy.protocol_fee_rate = new_rate;

        event::emit(UpdateFeeRateEvent {
            strategy_id: object::id(strategy),
            old_rate,
            new_rate,
        });
        new_rate
    }

    public(friend) fun update_strategy_default_base_rebalance_threshold(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        default_base_rebalance_percentage: u32,
    ): u32 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        strategy.default_base_rebalance_percentage = default_base_rebalance_percentage;

        default_base_rebalance_percentage
    }

    public(friend) fun update_strategy_default_limit_rebalance_threshold(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        default_limit_rebalance_percentage: u32,
    ): u32 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        strategy.default_limit_rebalance_percentage = default_limit_rebalance_percentage;

        default_limit_rebalance_percentage
    }

    public(friend) fun update_strategy_base_minimum_threshold(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        base_tick_step_minimum: u32,
    ): u32 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        strategy.base_tick_step_minimum = base_tick_step_minimum;

        base_tick_step_minimum
    }

    public(friend) fun update_strategy_limit_minimum_threshold(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        limit_tick_step_minimum: u32,
    ): u32 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        strategy.limit_tick_step_minimum = limit_tick_step_minimum;

        limit_tick_step_minimum
    }

    public(friend) fun update_vault_base_rebalance_threshold(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault_id: ID,
        base_rebalance_threshold: u32,
    ): u32 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        vault_info.base_rebalance_threshold = base_rebalance_threshold;

        base_rebalance_threshold
    }

    public(friend) fun update_vault_limit_rebalance_threshold(
        operator_cap: &OperatorCap,
        global_config: &GlobalConfig,
        strategy: &mut Strategy,
        vault_id: ID,
        limit_rebalance_threshold: u32,
    ): u32 {
        config::checked_package_version(global_config);
        let operator_address = object::id_address<OperatorCap>(operator_cap);
        config::check_vault_manager_role(global_config, operator_address);

        let vault_info = borrow_mut_vault_info(strategy, vault_id);
        vault_info.limit_rebalance_threshold = limit_rebalance_threshold;

        limit_rebalance_threshold
    }

    fun  borrow_mut_vault_account(
        strategy: &mut Strategy,
        vault_id: ID,
    ): &mut Account {
        table::borrow_mut(&mut strategy.accounts, vault_id)
    }

    public fun  borrow_vault_account(
        strategy: &Strategy,
        vault_id: ID,
    ): &Account {
        table::borrow(&strategy.accounts, vault_id)
    }

    fun  borrow_mut_vault_info(
        strategy: &mut Strategy,
        vault_id: ID,
    ): &mut VaultInfo {
        linked_table::borrow_mut(&mut strategy.vaults, vault_id)
    }

    public fun  borrow_vault_info(
        strategy: &Strategy,
        vault_id: ID,
    ): &VaultInfo {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info
    }

    fun  remove_vault_info(
        strategy: &mut Strategy,
        vault_id: ID,
    ): VaultInfo {
        linked_table::remove(&mut strategy.vaults, vault_id)
    }

    public fun  get_vault_info(
        strategy: &Strategy,
        vault_id: ID,
    ): (I32, I32, u128, I32, I32, u128, u128, u128, VecMap<TypeName, VaultRewardInfo>) {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        (
            vault_info.base_lower_index,
            vault_info.base_upper_index,
            vault_info.base_liquidity,
            vault_info.limit_lower_index,
            vault_info.limit_upper_index,
            vault_info.limit_liquidity,
            vault_info.sqrt_price,
            vault_info.share,
            vault_info.rewards,
        )
    }

    public fun  get_vault_base_liquidity(
        strategy: &Strategy,
        vault_id: ID,
    ): u128 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.base_liquidity
    }

    public fun  get_vault_base_last_tick_index(
        strategy: &Strategy,
        vault_id: ID,
    ): I32 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.base_last_tick_index
    }

    public fun  get_vault_limit_liquidity(
        strategy: &Strategy,
        vault_id: ID,
    ): u128 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.limit_liquidity
    }

    public fun  get_vault_limit_last_tick_index(
        strategy: &Strategy,
        vault_id: ID,
    ): I32 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.limit_last_tick_index
    }

    public fun  get_vault_base_lower_index(
        strategy: &Strategy,
        vault_id: ID,
    ): I32 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.base_lower_index
    }

    public fun  get_vault_base_upper_index(
        strategy: &Strategy,
        vault_id: ID,
    ): I32 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.base_upper_index
    }

    public fun  get_vault_base_clmm_position_id(
        strategy: &Strategy,
        vault_id: ID,
    ): ID {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.base_clmm_position_id
    }

    public fun  get_vault_limit_clmm_position_id(
        strategy: &Strategy,
        vault_id: ID,
    ): ID {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.limit_clmm_position_id
    }

    public fun  get_vault_limit_lower_index(
        strategy: &Strategy,
        vault_id: ID,
    ): I32 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.limit_lower_index
    }

    public fun  get_vault_limit_upper_index(
        strategy: &Strategy,
        vault_id: ID,
    ): I32 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.limit_upper_index
    }

    public fun  get_vault_sqrt_price(
        strategy: &Strategy,
        vault_id: ID,
    ): u128 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.sqrt_price
    }

    public fun  get_vault_share(
        strategy: &Strategy,
        vault_id: ID,
    ): u128 {
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        vault_info.share
    }

    public fun get_vault_balance<BalanceType>(
        strategy: &Strategy,
        vault_id: ID,
    ): u64 {
        let account = borrow_vault_account(strategy, vault_id);
        let type_name = get_type_name_str<BalanceType>();
        if (bag::contains<String>(&account.balances, type_name)) {
            let balance_ref = bag::borrow<String, Balance<BalanceType>>(&account.balances, type_name);
            balance::value<BalanceType>(balance_ref)
        } else {
            0
        }
    }

    public fun get_vault_total_amount<CoinTypeA, CoinTypeB, FeeType>(
        strategy: &Strategy,
        clmm_pool: &Pool<CoinTypeA, CoinTypeB, FeeType>,
        vault_id: ID,
    ): (u64, u64) {
        let amount_a = get_vault_balance<CoinTypeA>(strategy, vault_id);
        let amount_b = get_vault_balance<CoinTypeB>(strategy, vault_id);
        let vault_info = linked_table::borrow(&strategy.vaults, vault_id);
        let base_liquidity = vault_info.base_liquidity;
        let limit_liquidity = vault_info.limit_liquidity;
        let sqrt_price = pool::get_pool_sqrt_price(clmm_pool);
        if (base_liquidity > 0) {
            let (base_amount_a, base_amount_b) = math_liquidity::get_amount_for_liquidity(
                sqrt_price,
                math_tick::sqrt_price_from_tick_index(vault_info.base_lower_index),
                math_tick::sqrt_price_from_tick_index(vault_info.base_upper_index),
                base_liquidity
            );
            amount_a = amount_a + (base_amount_a as u64);
            amount_b = amount_b + (base_amount_b as u64);
        };
        if (limit_liquidity > 0) {
            let (limit_amount_a, limit_amount_b) = math_liquidity::get_amount_for_liquidity(
                sqrt_price,
                math_tick::sqrt_price_from_tick_index(vault_info.base_lower_index),
                math_tick::sqrt_price_from_tick_index(vault_info.base_upper_index),
                base_liquidity
            );
            amount_a = amount_a + (limit_amount_a as u64);
            amount_b = amount_b + (limit_amount_b as u64);
        };

        (amount_a, amount_b)
    }

    public fun get_strategy_status(
        strategy: &Strategy,
    ): u8 {
        strategy.status
    }

    public fun get_strategy_total_share(
        strategy: &Strategy,
    ): u128 {
        strategy.total_share
    }

    public fun get_strategy_tick_spacing(
        strategy: &Strategy,
    ): u32 {
        strategy.tick_spacing
    }

    public fun get_check_rebalance_info(
        check_rebalance: &CheckRebalance
    ): (bool, I32, I32, bool, I32, I32) {
        (
            check_rebalance.rebalance,
            check_rebalance.base_lower_index,
            check_rebalance.base_upper_index,
            check_rebalance.base_just_increase,
            check_rebalance.limit_lower_index,
            check_rebalance.limit_upper_index,
        )
    }

    fun  init_account_balance(
        strategy: &mut Strategy,
        vault_id: ID,
        ctx: &mut TxContext,
    ) {
        table::add(
            &mut strategy.accounts,
            vault_id,
            Account { 
                clmm_base_nft: option::none<TurbosPositionNFT>(),
                clmm_limit_nft: option::none<TurbosPositionNFT>(),
                balances: bag::new(ctx),
            }
        );
    }

    fun coin_to_vec<T>(coin: Coin<T>): vector<Coin<T>> {
        let self = vector::empty<Coin<T>>();
        vector::push_back(&mut self, coin);
        self
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(VAULT{} ,ctx);
    }

    #[test]
    fun test_floor_tick_index() {
        let (curent_index, tick_spacing) = (
            i32::from(10), 
            10, 
        );
        let tick_index = floor_tick_index(curent_index, tick_spacing, false);
        assert!(i32::eq(tick_index, i32::from(10)), 1);
        let tick_index = floor_tick_index(curent_index, tick_spacing, true);
        assert!(i32::eq(tick_index, i32::from(10)), 1);

        let (curent_index, tick_spacing) = (
            i32::from(11), 
            10, 
        );
        let tick_index = floor_tick_index(curent_index, tick_spacing, false);
        assert!(i32::eq(tick_index, i32::from(20)), 1);
        let tick_index = floor_tick_index(curent_index, tick_spacing, true);
        assert!(i32::eq(tick_index, i32::from(10)), 1);

        let (curent_index, tick_spacing) = (
            i32::from(9), 
            10, 
        );
        let tick_index = floor_tick_index(curent_index, tick_spacing, false);
        assert!(i32::eq(tick_index, i32::from(10)), 1);
        let tick_index = floor_tick_index(curent_index, tick_spacing, true);
        assert!(i32::eq(tick_index, i32::from(0)), 1);

        let (curent_index, tick_spacing) = (
            i32::neg_from(10), 
            10, 
        );
        let tick_index = floor_tick_index(curent_index, tick_spacing, false);
        assert!(i32::eq(tick_index, i32::neg_from(10)), 1);
        let tick_index = floor_tick_index(curent_index, tick_spacing, true);
        assert!(i32::eq(tick_index, i32::neg_from(10)), 1);

        let (curent_index, tick_spacing) = (
            i32::neg_from(11), 
            10, 
        );
        let tick_index = floor_tick_index(curent_index, tick_spacing, false);
        assert!(i32::eq(tick_index, i32::neg_from(10)), 1);
        let tick_index = floor_tick_index(curent_index, tick_spacing, true);
        assert!(i32::eq(tick_index, i32::neg_from(20)), 1);

        let (curent_index, tick_spacing) = (
            i32::neg_from(9), 
            10, 
        );
        let tick_index = floor_tick_index(curent_index, tick_spacing, false);
        assert!(i32::eq(tick_index, i32::from(0)), 1);
        let tick_index = floor_tick_index(curent_index, tick_spacing, true);
        assert!(i32::eq(tick_index, i32::neg_from(10)), 1);
    }

    #[test]
    fun test_calculate_tick_index() {
        let (curent_index, tick_spacing, step) = (
            i32::from(10), 
            10, 
            0
        );
        let (lower_index, upper_index) = calculate_tick_index(
            curent_index,
            tick_spacing,
            step,
        );
        assert!(i32::eq(lower_index, i32::from(0)), 1);
        assert!(i32::eq(upper_index, i32::from(20)), 1);

        curent_index = i32::neg_from(10);
        (lower_index, upper_index) = calculate_tick_index(
            curent_index,
            tick_spacing,
            step,
        );
        assert!(i32::eq(lower_index, i32::neg_from(20)), 1);
        assert!(i32::eq(upper_index, i32::from(0)), 1);

        curent_index = i32::from(9);
        (lower_index, upper_index) = calculate_tick_index(
            curent_index,
            tick_spacing,
            step,
        );
        assert!(i32::eq(lower_index, i32::neg_from(10)), 1);
        assert!(i32::eq(upper_index, i32::from(10)), 1);

        curent_index = i32::neg_from(9);
        (lower_index, upper_index) = calculate_tick_index(
            curent_index,
            tick_spacing,
            step,
        );
        assert!(i32::eq(lower_index, i32::neg_from(10)), 1);
        assert!(i32::eq(upper_index, i32::from(10)), 1);
    }
}