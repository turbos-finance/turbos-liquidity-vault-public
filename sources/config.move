// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_assets_manage::config {
    use turbos_assets_manage::acl::{Self, ACL, Member};
    use sui::event;
    use sui::object::{Self, ID, UID};
    use sui::table::{Self, Table};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::vec_map::{Self, VecMap};

    friend turbos_assets_manage::router;

    const EWrongVersion: u64 = 0;
    const EWrongVaultManager: u64 =1;
    const EWrongRewardManager: u64 = 2;
    const EWrongRebalanceManager: u64 = 3;
    const EInvilidRebate: u64 = 4;
    const EInvilidDiscount: u64 = 5;

    const VERSION: u64 = 1;
    const TIER_RATE_SCALE: u64 = 1000000;

    struct AdminCap has store, key {
	    id: UID
    }
    
    struct OperatorCap has key {
	    id: UID
    }

    struct Tier has copy, drop, store {
        rebate: u64, // e.g. 240000 for 24%
        discount: u64, // 50000 for 5% discount
    }

    struct GlobalConfig has store, key {
	    id: UID,
	    acl: ACL,
	    package_version: u64,
        user_tiers: VecMap<address, Tier>,
    }

    struct UserTierConfig has store, key {
	    id: UID,
        user_tiers: Table<address, Tier>,
    }

    struct InitConfigEvent has copy, drop {
	    admin_cap_id: ID,
	    global_config_id: ID
    }

    struct AddOperatorEvent has copy, drop {
	    operator_cap_id: ID,
	    recipient: address,
	    roles: u128
    }
    
    struct SetRolesEvent has copy, drop {
	    member: address,
	    roles: u128
    }
    
    struct AddRoleEvent has copy, drop {
	    member: address,
	    role: u8
    }

    struct RemoveRoleEvent has copy, drop {
	    member: address,
	    role: u8
    }
    
    struct RemoveMemberEvent has copy, drop {
	    member: address
    }

    struct SetPackageVersion has copy, drop {
	    new_version: u64,
	    old_version: u64
    }

    struct SetTierEvent has copy, drop {
	    user: address,
	    rebate: u64,
        discount: u64,
    }

    struct InitUserTierConfigEvent has copy, drop {
	    admin_cap_id: ID,
	    user_tier_config_id: ID
    }

    fun init(ctx: &mut TxContext) {
        let admin_cap= AdminCap {
            id: object::new(ctx),
        };
        let acl = acl::new(ctx);
        let global_config = GlobalConfig {
            id: object::new(ctx),
            acl,
            package_version: 1,
            user_tiers: vec_map::empty(),
        };
        let admin_cap_id = object::id(&admin_cap);
        let global_config_id = object::id(&global_config);
        transfer::public_transfer(admin_cap, tx_context::sender(ctx));
        transfer::public_share_object(global_config);
        event::emit(InitConfigEvent {
            admin_cap_id,
            global_config_id,
        });
    }

    public(friend) fun new_user_tier_config(admin_cap: &AdminCap, ctx: &mut TxContext) {
        let user_tier_config = UserTierConfig {
            id: object::new(ctx),
            user_tiers: table::new(ctx),
        };
        let admin_cap_id = object::id(admin_cap);
        let user_tier_config_id = object::id(&user_tier_config);
        transfer::public_share_object(user_tier_config);

        event::emit(InitUserTierConfigEvent {
            admin_cap_id,
            user_tier_config_id,
        });
    }

    public(friend) fun add_operator(admin_cap: &AdminCap, global_config: &mut GlobalConfig, roles: u128, recipient: address, ctx: &mut TxContext) {
        checked_package_version(global_config);
        let operator_cap = OperatorCap { id: object::new(ctx) };
        let operator_id = object::id(&operator_cap);
        acl::set_roles(&mut global_config.acl, object::id_address(&operator_cap), roles);
        transfer::transfer(operator_cap, recipient);
        event::emit(AddOperatorEvent {
            operator_cap_id: operator_id,
            recipient,
            roles,
        });
    }

    public(friend) fun set_roles(admin_cap: &AdminCap, global_config: &mut GlobalConfig, member: address, roles: u128) {
        checked_package_version(global_config);
        acl::set_roles(&mut global_config.acl, member, roles);
        event::emit(SetRolesEvent { member, roles });
    }


    public(friend) fun add_role(admin_cap: &AdminCap, global_config: &mut GlobalConfig, member: address, role: u8) {
        checked_package_version(global_config);
        acl::add_role(&mut global_config.acl, member, role);
        event::emit(AddRoleEvent { member, role });
    }

    public(friend) fun remove_role(admin_cap: &AdminCap, global_config: &mut GlobalConfig, member: address, role: u8) {
        checked_package_version(global_config);
        acl::remove_role(&mut global_config.acl, member, role);
        event::emit(RemoveRoleEvent { member, role });
    }

    public(friend) fun remove_member(admin_cap: &AdminCap, global_config: &mut GlobalConfig, member: address) {
        checked_package_version(global_config);
        acl::remove_member(&mut global_config.acl, member);
        event::emit(RemoveMemberEvent { member });
    }

    public(friend) fun set_package_version(admin_cap: &AdminCap, global_config: &mut GlobalConfig, new_version: u64) {
        let old_version = global_config.package_version;
        assert!(new_version > old_version, EWrongVersion);
        global_config.package_version = new_version;
        event::emit(SetPackageVersion { new_version, old_version });
    }

    public(friend) fun set_tier(
        admin_cap: &AdminCap,
        global_config: &mut GlobalConfig,
        user: address,
        rebate: u64,
        discount: u64,
        ctx: &mut TxContext,
    ) {
        abort(0)
    }

    public(friend) fun set_tier_v2(
        admin_cap: &AdminCap,
        global_config: &GlobalConfig,
        user_tier_config: &mut UserTierConfig,
        user: address,
        rebate: u64,
        discount: u64,
        ctx: &mut TxContext,
    ) {
        checked_package_version(global_config);
        assert!(rebate <= TIER_RATE_SCALE, EInvilidRebate);
        assert!(discount <= TIER_RATE_SCALE, EInvilidDiscount);
        if (table::contains(&user_tier_config.user_tiers, user)) {
            let tier = table::borrow_mut(&mut user_tier_config.user_tiers, user);
            tier.rebate = rebate;
            tier.discount = discount;
        } else {
            table::add(&mut user_tier_config.user_tiers, user, Tier {
                rebate,
                discount,
            });
        };
        
        event::emit(SetTierEvent {
            user,
            rebate,
            discount,
        })
    }

    public fun get_tier(
        global_config: &GlobalConfig,
        user: address,
    ): (u64, u64) {
        abort(0)
    }

    public fun get_tier_v2(
        global_config: &GlobalConfig,
        user_tier_config: &mut UserTierConfig,
        user: address,
    ): (u64, u64) {
        checked_package_version(global_config);
        if (table::contains(&user_tier_config.user_tiers, user)) {
            let tier = table::borrow(&user_tier_config.user_tiers, user);
            (tier.rebate, tier.discount)
        } else {
            (0, 0)
        }
    }

    public fun get_members(global_config: &GlobalConfig): vector<Member> {
        acl::get_members(&global_config.acl)
    }

    public fun check_vault_manager_role(global_config: &GlobalConfig, addr: address) {
        assert!(acl::has_role(&global_config.acl, addr, 0), EWrongVaultManager);
    }

    public fun check_reward_manager_role(global_config: &GlobalConfig, addr: address) {
        assert!(acl::has_role(&global_config.acl, addr, 1), EWrongRewardManager);
    }

    public fun check_rebalance_manager_role(global_config: &GlobalConfig, addr: address) {
        assert!(acl::has_role(&global_config.acl, addr, 2), EWrongRebalanceManager);
    }

    public fun checked_package_version(global_config: &GlobalConfig) {
        assert!(global_config.package_version == VERSION, EWrongVersion);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}