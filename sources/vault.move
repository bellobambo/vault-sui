module vault::vault {
    use std::string::String;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::sui::SUI;

    /// A daily budget cycle.
    const CYCLE_DAILY: u8 = 0;
    /// A weekly budget cycle.
    const CYCLE_WEEKLY: u8 = 1;
    /// A monthly budget cycle.
    const CYCLE_MONTHLY: u8 = 2;
    /// A half-year budget cycle.
    const CYCLE_HALF_YEAR: u8 = 3;
    /// A yearly budget cycle.
    const CYCLE_YEARLY: u8 = 4;

    const ACTION_SAVE: u8 = 0;
    const ACTION_ROLL_OVER: u8 = 1;
    const ACTION_WITHDRAW: u8 = 2;
    const ACTION_REDISTRIBUTE: u8 = 3;

    const SWAP_FEE_BPS: u64 = 500;
    const OVERSPEND_FEE_BPS: u64 = 1000;
    const CATEGORY_OTHER: u8 = 4;

    const E_NOT_OWNER: u64 = 0;
    const E_NOT_ACTIVE: u64 = 1;
    const E_EXPIRED: u64 = 2;
    const E_INVALID_CYCLE: u64 = 3;
    const E_INVALID_DATES: u64 = 4;
    const E_EMPTY_CATEGORIES: u64 = 5;
    const E_LENGTH_MISMATCH: u64 = 6;
    const E_ALLOCATION_MISMATCH: u64 = 7;
    const E_CATEGORY_NOT_FOUND: u64 = 8;
    const E_CATEGORY_EXHAUSTED: u64 = 9;
    const E_INSUFFICIENT_VAULT_BALANCE: u64 = 10;
    const E_INSUFFICIENT_UNUSED_ALLOCATION: u64 = 11;
    const E_OVERSPEND_DISABLED: u64 = 12;
    const E_INVALID_FEE: u64 = 13;
    const E_STILL_ACTIVE: u64 = 14;
    const E_INVALID_END_ACTION: u64 = 15;
    const E_NO_BALANCE: u64 = 16;
    const E_INVALID_REDISTRIBUTION: u64 = 17;
    const E_OTHER_CATEGORY_TOO_HIGH: u64 = 18;

    public struct BudgetVault has key {
        id: UID,
        owner: address,
        cycle: u8,
        start_ms: u64,
        end_ms: u64,
        active: bool,
        allow_overspend: bool,
        total_deposited: u64,
        total_spent: u64,
        total_fees_paid: u64,
        balance: Balance<SUI>,
        categories: vector<Category>,
        /// Offchain pointer for the AI memory record stored with Walrus/MemWal.
        memory_ref: vector<u8>,
    }

    public struct TreasuryConfig has key {
        id: UID,
        treasury: address,
    }

    public struct Category has store, drop {
        id: u8,
        name: String,
        allocation: u64,
        spent: u64,
        overspent: u64,
    }

    public struct BudgetCreated has copy, drop {
        vault_id: ID,
        owner: address,
        cycle: u8,
        start_ms: u64,
        end_ms: u64,
        amount: u64,
        allow_overspend: bool,
        swap_fee_bps: u64,
        overspend_fee_bps: u64,
        memory_ref: vector<u8>,
    }

    public struct TreasuryCreated has copy, drop {
        config_id: ID,
        treasury: address,
    }

    public struct CategorySwap has copy, drop {
        vault_id: ID,
        owner: address,
        from_category: u8,
        to_category: u8,
        amount: u64,
        fee: u64,
        timestamp_ms: u64,
        memory_ref: vector<u8>,
    }

    public struct BudgetSpend has copy, drop {
        vault_id: ID,
        owner: address,
        recipient: address,
        category: u8,
        amount: u64,
        fee: u64,
        overspend: bool,
        note: vector<u8>,
        timestamp_ms: u64,
        memory_ref: vector<u8>,
    }

    public struct BudgetClosed has copy, drop {
        vault_id: ID,
        owner: address,
        action: u8,
        amount: u64,
        timestamp_ms: u64,
        memory_ref: vector<u8>,
    }

    public struct SavingsVault has key {
        id: UID,
        owner: address,
        balance: Balance<SUI>,
        memory_ref: vector<u8>,
    }

    fun init(ctx: &mut TxContext) {
        let treasury = tx_context::sender(ctx);
        let config = TreasuryConfig {
            id: object::new(ctx),
            treasury,
        };

        event::emit(TreasuryCreated {
            config_id: object::id(&config),
            treasury,
        });

        transfer::share_object(config);
    }

    public fun cycle_daily(): u8 { CYCLE_DAILY }

    public fun cycle_weekly(): u8 { CYCLE_WEEKLY }

    public fun cycle_monthly(): u8 { CYCLE_MONTHLY }

    public fun cycle_half_year(): u8 { CYCLE_HALF_YEAR }

    public fun cycle_yearly(): u8 { CYCLE_YEARLY }

    public fun action_save(): u8 { ACTION_SAVE }

    public fun action_roll_over(): u8 { ACTION_ROLL_OVER }

    public fun action_withdraw(): u8 { ACTION_WITHDRAW }

    public fun action_redistribute(): u8 { ACTION_REDISTRIBUTE }

    public fun swap_fee_bps(): u64 { SWAP_FEE_BPS }

    public fun overspend_fee_bps(): u64 { OVERSPEND_FEE_BPS }

    public fun create_budget(
        deposit: Coin<SUI>,
        cycle: u8,
        start_ms: u64,
        end_ms: u64,
        category_ids: vector<u8>,
        category_names: vector<String>,
        allocations: vector<u64>,
        allow_overspend: bool,
        memory_ref: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert_valid_cycle(cycle);
        assert!(start_ms < end_ms, E_INVALID_DATES);

        let count = category_ids.length();
        assert!(count > 0, E_EMPTY_CATEGORIES);
        assert!(count == category_names.length(), E_LENGTH_MISMATCH);
        assert!(count == allocations.length(), E_LENGTH_MISMATCH);

        let amount = coin::value(&deposit);
        let mut sum = 0;
        let mut i = 0;
        let mut categories = vector[];
        while (i < count) {
            let allocation = *allocations.borrow(i);
            sum = sum + allocation;
            categories.push_back(Category {
                id: *category_ids.borrow(i),
                name: *category_names.borrow(i),
                allocation,
                spent: 0,
                overspent: 0,
            });
            i = i + 1;
        };
        assert!(sum == amount, E_ALLOCATION_MISMATCH);
        assert_other_not_above_main_average(&categories);

        let owner = tx_context::sender(ctx);
        let balance = coin::into_balance(deposit);
        let vault = BudgetVault {
            id: object::new(ctx),
            owner,
            cycle,
            start_ms,
            end_ms,
            active: true,
            allow_overspend,
            total_deposited: amount,
            total_spent: 0,
            total_fees_paid: 0,
            balance,
            categories,
            memory_ref,
        };

        event::emit(BudgetCreated {
            vault_id: object::id(&vault),
            owner,
            cycle,
            start_ms,
            end_ms,
            amount,
            allow_overspend,
            swap_fee_bps: SWAP_FEE_BPS,
            overspend_fee_bps: OVERSPEND_FEE_BPS,
            memory_ref: vault.memory_ref,
        });

        transfer::transfer(vault, owner);
    }

    public fun spend(
        vault: &mut BudgetVault,
        category_id: u8,
        recipient: address,
        amount: u64,
        note: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_owner_and_active(vault, clock, ctx);
        assert!(balance::value(&vault.balance) >= amount, E_INSUFFICIENT_VAULT_BALANCE);

        let idx = category_index(vault, category_id);
        let category = vault.categories.borrow_mut(idx);
        assert!(unused_allocation(category) >= amount, E_CATEGORY_EXHAUSTED);

        category.spent = category.spent + amount;
        vault.total_spent = vault.total_spent + amount;

        let payment = coin::take(&mut vault.balance, amount, ctx);
        transfer::public_transfer(payment, recipient);

        event::emit(BudgetSpend {
            vault_id: object::id(vault),
            owner: vault.owner,
            recipient,
            category: category_id,
            amount,
            fee: 0,
            overspend: false,
            note,
            timestamp_ms: clock::timestamp_ms(clock),
            memory_ref: vault.memory_ref,
        });
    }

    public fun swap_categories(
        config: &TreasuryConfig,
        vault: &mut BudgetVault,
        from_category_id: u8,
        to_category_id: u8,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_owner_and_active(vault, clock, ctx);

        let from_idx = category_index(vault, from_category_id);
        let to_idx = category_index(vault, to_category_id);
        assert!(from_idx != to_idx, E_INVALID_REDISTRIBUTION);

        let fee = fee_for(amount, SWAP_FEE_BPS);
        assert!(balance::value(&vault.balance) >= fee, E_INVALID_FEE);

        let from = vault.categories.borrow_mut(from_idx);
        assert!(unused_allocation(from) >= amount, E_INSUFFICIENT_UNUSED_ALLOCATION);
        from.allocation = from.allocation - amount;

        let to = vault.categories.borrow_mut(to_idx);
        to.allocation = to.allocation + amount;

        pay_fee(vault, fee, config.treasury, ctx);

        event::emit(CategorySwap {
            vault_id: object::id(vault),
            owner: vault.owner,
            from_category: from_category_id,
            to_category: to_category_id,
            amount,
            fee,
            timestamp_ms: clock::timestamp_ms(clock),
            memory_ref: vault.memory_ref,
        });
    }

    public fun overspend(
        config: &TreasuryConfig,
        vault: &mut BudgetVault,
        category_id: u8,
        recipient: address,
        amount: u64,
        note: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_owner_and_active(vault, clock, ctx);
        assert!(vault.allow_overspend, E_OVERSPEND_DISABLED);

        let fee = fee_for(amount, OVERSPEND_FEE_BPS);
        let total = amount + fee;
        assert!(balance::value(&vault.balance) >= total, E_INSUFFICIENT_VAULT_BALANCE);

        let idx = category_index(vault, category_id);
        let category = vault.categories.borrow_mut(idx);
        let remaining = unused_allocation(category);
        assert!(remaining < amount, E_CATEGORY_EXHAUSTED);
        let overspent_amount = amount - remaining;

        category.spent = category.spent + amount;
        category.overspent = category.overspent + overspent_amount;
        vault.total_spent = vault.total_spent + amount;

        let payment = coin::take(&mut vault.balance, amount, ctx);
        transfer::public_transfer(payment, recipient);
        pay_fee(vault, fee, config.treasury, ctx);

        event::emit(BudgetSpend {
            vault_id: object::id(vault),
            owner: vault.owner,
            recipient,
            category: category_id,
            amount,
            fee,
            overspend: true,
            note,
            timestamp_ms: clock::timestamp_ms(clock),
            memory_ref: vault.memory_ref,
        });
    }

    public fun close_budget(
        vault: BudgetVault,
        action: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let BudgetVault {
            id,
            owner,
            cycle: _,
            start_ms: _,
            end_ms,
            active: _,
            allow_overspend: _,
            total_deposited: _,
            total_spent: _,
            total_fees_paid: _,
            balance,
            categories: _,
            memory_ref,
        } = vault;

        assert!(tx_context::sender(ctx) == owner, E_NOT_OWNER);
        assert!(clock::timestamp_ms(clock) >= end_ms, E_STILL_ACTIVE);
        assert_valid_end_action(action);

        let amount = balance::value(&balance);
        assert!(amount > 0, E_NO_BALANCE);
        event::emit(BudgetClosed {
            vault_id: object::uid_to_inner(&id),
            owner,
            action,
            amount,
            timestamp_ms: clock::timestamp_ms(clock),
            memory_ref,
        });

        object::delete(id);

        if (action == ACTION_SAVE) {
            let savings = SavingsVault {
                id: object::new(ctx),
                owner,
                balance,
                memory_ref,
            };
            transfer::transfer(savings, owner);
        } else {
            let coin = coin::from_balance(balance, ctx);
            transfer::public_transfer(coin, owner);
        }
    }

    public fun redistribute_budget(
        vault: &mut BudgetVault,
        cycle: u8,
        start_ms: u64,
        end_ms: u64,
        category_ids: vector<u8>,
        category_names: vector<String>,
        allocations: vector<u64>,
        allow_overspend: bool,
        memory_ref: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        assert!(clock::timestamp_ms(clock) >= vault.end_ms, E_STILL_ACTIVE);
        assert_valid_cycle(cycle);
        assert!(start_ms < end_ms, E_INVALID_DATES);

        let amount = balance::value(&vault.balance);
        let count = category_ids.length();
        assert!(count > 0, E_EMPTY_CATEGORIES);
        assert!(count == category_names.length(), E_LENGTH_MISMATCH);
        assert!(count == allocations.length(), E_LENGTH_MISMATCH);

        let mut sum = 0;
        let mut i = 0;
        let mut categories = vector[];
        while (i < count) {
            let allocation = *allocations.borrow(i);
            sum = sum + allocation;
            categories.push_back(Category {
                id: *category_ids.borrow(i),
                name: *category_names.borrow(i),
                allocation,
                spent: 0,
                overspent: 0,
            });
            i = i + 1;
        };
        assert!(sum == amount, E_ALLOCATION_MISMATCH);
        assert_other_not_above_main_average(&categories);

        event::emit(BudgetClosed {
            vault_id: object::id(vault),
            owner: vault.owner,
            action: ACTION_REDISTRIBUTE,
            amount,
            timestamp_ms: clock::timestamp_ms(clock),
            memory_ref: vault.memory_ref,
        });

        vault.cycle = cycle;
        vault.start_ms = start_ms;
        vault.end_ms = end_ms;
        vault.active = true;
        vault.allow_overspend = allow_overspend;
        vault.total_deposited = amount;
        vault.total_spent = 0;
        vault.total_fees_paid = 0;
        vault.categories = categories;
        vault.memory_ref = memory_ref;
    }

    public fun withdraw_savings(
        savings: SavingsVault,
        ctx: &mut TxContext,
    ) {
        let SavingsVault { id, owner, balance, memory_ref: _ } = savings;
        assert!(tx_context::sender(ctx) == owner, E_NOT_OWNER);
        object::delete(id);
        let coin = coin::from_balance(balance, ctx);
        transfer::public_transfer(coin, owner);
    }

    public fun owner(vault: &BudgetVault): address { vault.owner }

    public fun is_active(vault: &BudgetVault): bool { vault.active }

    public fun total_spent(vault: &BudgetVault): u64 { vault.total_spent }

    public fun total_fees_paid(vault: &BudgetVault): u64 { vault.total_fees_paid }

    public fun vault_balance(vault: &BudgetVault): u64 { balance::value(&vault.balance) }

    public fun treasury(config: &TreasuryConfig): address { config.treasury }

    public fun category_count(vault: &BudgetVault): u64 { vault.categories.length() }

    public fun category_remaining(vault: &BudgetVault, category_id: u8): u64 {
        let idx = category_index(vault, category_id);
        unused_allocation(vault.categories.borrow(idx))
    }

    public fun category_spent(vault: &BudgetVault, category_id: u8): u64 {
        let idx = category_index(vault, category_id);
        vault.categories.borrow(idx).spent
    }

    fun assert_owner_and_active(vault: &BudgetVault, clock: &Clock, ctx: &TxContext) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        assert!(vault.active, E_NOT_ACTIVE);
        assert!(clock::timestamp_ms(clock) >= vault.start_ms, E_NOT_ACTIVE);
        assert!(clock::timestamp_ms(clock) <= vault.end_ms, E_EXPIRED);
    }

    fun assert_valid_cycle(cycle: u8) {
        assert!(
            cycle == CYCLE_DAILY ||
                cycle == CYCLE_WEEKLY ||
                cycle == CYCLE_MONTHLY ||
                cycle == CYCLE_HALF_YEAR ||
                cycle == CYCLE_YEARLY,
            E_INVALID_CYCLE,
        );
    }

    fun assert_valid_end_action(action: u8) {
        assert!(
            action == ACTION_SAVE ||
                action == ACTION_ROLL_OVER ||
                action == ACTION_WITHDRAW,
            E_INVALID_END_ACTION,
        );
    }

    fun category_index(vault: &BudgetVault, category_id: u8): u64 {
        let mut i = 0;
        let count = vault.categories.length();
        while (i < count) {
            if (vault.categories.borrow(i).id == category_id) {
                return i
            };
            i = i + 1;
        };
        abort E_CATEGORY_NOT_FOUND
    }

    fun unused_allocation(category: &Category): u64 {
        if (category.spent >= category.allocation) {
            0
        } else {
            category.allocation - category.spent
        }
    }

    fun assert_other_not_above_main_average(categories: &vector<Category>) {
        let mut i = 0;
        let count = categories.length();
        let mut main_sum = 0;
        let mut main_count = 0;
        let mut other_allocation = 0;
        let mut has_other = false;

        while (i < count) {
            let category = categories.borrow(i);
            if (category.id == CATEGORY_OTHER) {
                other_allocation = category.allocation;
                has_other = true;
            } else {
                main_sum = main_sum + category.allocation;
                main_count = main_count + 1;
            };
            i = i + 1;
        };

        if (has_other) {
            assert!(main_count > 0, E_OTHER_CATEGORY_TOO_HIGH);
            assert!(other_allocation * main_count <= main_sum, E_OTHER_CATEGORY_TOO_HIGH);
        }
    }

    fun fee_for(amount: u64, bps: u64): u64 {
        (amount * bps) / 10000
    }

    fun pay_fee(vault: &mut BudgetVault, fee: u64, fee_recipient: address, ctx: &mut TxContext) {
        if (fee > 0) {
            assert!(balance::value(&vault.balance) >= fee, E_INSUFFICIENT_VAULT_BALANCE);
            vault.total_fees_paid = vault.total_fees_paid + fee;
            let fee_coin = coin::take(&mut vault.balance, fee, ctx);
            transfer::public_transfer(fee_coin, fee_recipient);
        }
    }
}
