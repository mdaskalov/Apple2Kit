import MOS6502

/// A hook put in with `Apple2Machine.addHook` or `addObserver`, to take it
/// out again (`removeHook`).
public nonisolated struct HookID: Hashable, Sendable {
    let value: Int
}

/// The machine's hooks (`Apple2Machine.addHook`): Swift run where the CPU
/// reaches an address, before the instruction there; and its natives
/// (`addNative`), run where a JSR calls a routine.  They own the CPU's trap
/// bits (`CPU6502.traps`, `callTraps`): a bit is set while a hook (a native)
/// switched on is at its address, or the mouse card's firmware.
nonisolated struct Hooks {
    enum Kind {
        /// True: it handled the instruction.
        case hook((Apple2Machine) -> Bool)
        /// It only looks: the next hook, and the instruction, run after it.
        case observer((Apple2Machine) -> Void)
        /// Run where a JSR calls the address (`Apple2Machine.addNative`).
        case native(maxSteps: Int, (NativeCall) -> UInt64)
    }

    struct Hook {
        let id: HookID
        let address: UInt16
        /// Its switch (`Apple2Machine.switchedOff`); nil: always on.
        let name: String?
        let kind: Kind

        var observes: Bool { if case .observer = kind { true } else { false } }
        var isNative: Bool { if case .native = kind { true } else { false } }
    }

    /// Every hook, and their order at each address.
    var all: [HookID: Hook] = [:]
    var order: [UInt16: [HookID]] = [:]
    /// The hooks and observers switched on at each address, observers first.
    var active: [UInt16: [Hook]] = [:]
    /// The native switched on at each address (the first put in).
    var natives: [UInt16: Hook] = [:]
    var switchedOff: Set<String> = []
    private var next = 0
    /// Counts every change, so a dispatch sees a hook taken out under it.
    private(set) var changes = 0

    mutating func add(_ address: UInt16, name: String?, kind: Kind, first: Bool = false) -> HookID {
        next += 1
        let id = HookID(value: next)
        all[id] = Hook(id: id, address: address, name: name, kind: kind)
        if first { order[address, default: []].insert(id, at: 0) } else { order[address, default: []].append(id) }
        update(address)
        return id
    }

    /// Takes out `id`; its address, if there was one.
    mutating func remove(_ id: HookID) -> UInt16? {
        guard let hook = all.removeValue(forKey: id) else { return nil }
        order[hook.address]?.removeAll { $0 == id }
        if order[hook.address]?.isEmpty == true { order[hook.address] = nil }
        update(hook.address)
        return hook.address
    }

    /// The hooks switched on at `address`, observers first, in order; its native.
    mutating func update(_ address: UInt16) {
        changes += 1
        let on = (order[address] ?? []).compactMap { all[$0] }.filter { $0.name.map { !switchedOff.contains($0) } ?? true }
        let list = on.filter(\.observes) + on.filter { !$0.observes && !$0.isNative }
        active[address] = list.isEmpty ? nil : list
        natives[address] = on.first(where: \.isNative)
    }

    /// The addresses with a hook, an observer or a native switched on.
    var hooked: Set<UInt16> { Set(active.keys).union(natives.keys) }

    /// The addresses with a hook that has a name.
    var switchable: Set<UInt16> { Set(all.values.filter { $0.name != nil }.map(\.address)) }
}

public nonisolated extension Apple2Machine {
    /// Puts in a hook at `address`: `run` is called where the CPU gets there,
    /// before the instruction, with the machine.  True: it handled it – it
    /// set the CPU up to go on, PC and all (a routine run in Swift returns
    /// with `cpu.returnFromSubroutine()`); false: the instruction runs (or
    /// the next hook there).  One with a `name` can be switched off
    /// (`switchedOff`).  The hooks at an address run in the order put in,
    /// after the observers there.
    @discardableResult
    func addHook(at address: UInt16, name: String? = nil, _ run: @escaping (Apple2Machine) -> Bool) -> HookID {
        let id = hooks.add(address, name: name, kind: .hook(run))
        refreshTrap(address)
        return id
    }

    /// Puts in an observer at `address`: `look` is called where the CPU gets
    /// there, before the hooks and the instruction, which then run as ever.
    /// `first`: before the observers there already.
    @discardableResult
    func addObserver(at address: UInt16, name: String? = nil, first: Bool = false, _ look: @escaping (Apple2Machine) -> Void) -> HookID {
        let id = hooks.add(address, name: name, kind: .observer(look), first: first)
        refreshTrap(address)
        return id
    }

    /// Takes a hook, an observer or a native out; its trap goes with the last at its address.
    func removeHook(_ id: HookID) {
        if let address = hooks.remove(id) { refreshTrap(address) }
    }

    /// The names of the hooks switched off: they stay put in, but don't run,
    /// and the CPU doesn't stop at their address for them – the
    /// instruction there runs as without them.  From the next instruction on.
    var switchedOff: Set<String> {
        get { hooks.switchedOff }
        set {
            guard newValue != hooks.switchedOff else { return }
            hooks.switchedOff = newValue
            for address in hooks.switchable {
                hooks.update(address)
                refreshTrap(address)
            }
        }
    }

    /// A hook or an observer switched on is at `address`.
    @inline(__always)
    func isHooked(_ address: UInt16) -> Bool { hooks.active[address] != nil }

    /// The trap at `address` is set while a hook switched on is there, or
    /// the mouse card's firmware; the call trap while a native is.
    internal func refreshTrap(_ address: UInt16) {
        cpu.traps[Int(address)] = hooks.active[address] != nil
            || mouseEnabled && MouseCard.Call.allCases.contains { $0.entry == address }
        cpu.callTraps[Int(address)] = hooks.natives[address] != nil
    }

    /// The hooks at `pc`; true: one handled the instruction.
    internal func runHooks(at pc: UInt16) -> Bool {
        guard let list = hooks.active[pc] else { return false }
        let changes = hooks.changes
        for hook in list {
            // one taken out by a hook before it doesn't run
            if hooks.changes != changes, hooks.all[hook.id] == nil { continue }
            switch hook.kind {
            case .observer(let look): look(self)
            case .hook(let run): if run(self) { return true }
            case .native: break
            }
        }
        return false
    }
}
