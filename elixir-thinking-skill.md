# Elixir Thinking

Mental shifts required before writing Elixir. These contradict conventional OOP patterns.

## The Iron Law

```
NO PROCESS WITHOUT A RUNTIME REASON
```

Before creating a GenServer, Agent, or any process, answer YES to at least one:
1. Do I need mutable state persisting across calls?
2. Do I need concurrent execution?
3. Do I need fault isolation?

**All three are NO?** Use plain functions. Modules organize code; processes manage runtime.

## The Three Decoupled Dimensions

OOP couples behavior, state, and mutability together. Elixir decouples them:

| OOP Dimension | Elixir Equivalent |
|---------------|-------------------|
| Behavior | Modules (functions) |
| State | Data (structs, maps) |
| Mutability | Processes (GenServer) |

Pick only what you need. "I only need data and functions" = no process needed.

## "Let It Crash" = "Let It Heal"

The misconception: Write careless code.
The truth: Supervisors START processes.

- Handle expected errors explicitly (`{:ok, _}` / `{:error, _}`)
- Let unexpected errors crash → supervisor restarts

## Control Flow

**Pattern matching first:**
- Match on function heads instead of `if/else` or `case` in bodies
- `%{}` matches ANY map—use `map_size(map) == 0` guard for empty maps
- Avoid nested `case`—refactor to single `case`, `with`, or separate functions

**Error handling:**
- Use `{:ok, result}` / `{:error, reason}` for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining `{:ok, _}` / `{:error, _}` operations

**Be explicit about expected cases:**
- Avoid `_ -> nil` catch-alls—they silently swallow unexpected cases
- Avoid `value && value.field` nil-punning—obscures actual return types
- When a case has `{:ok, nil} -> nil` alongside `{:ok, value} -> value.field`, use `with` instead:

```elixir
# Verbose
case get_run(id) do
  {:ok, nil} -> nil
  {:ok, run} -> run.recommendations
end

# Prefer
with {:ok, %{recommendations: recs}} <- get_run(id), do: recs
```

## Polymorphism

| For Polymorphism Over... | Use | Contract |
|--------------------------|-----|----------|
| Modules | Behaviors | Upfront callbacks |
| Data | Protocols | Upfront implementations |
| Processes | Message passing | Implicit (send/receive) |

**Behaviors** = default for module polymorphism (very cheap at runtime)
**Protocols** = only when composing data types, especially built-ins
**Message passing** = for events, pub/sub, actor patterns
