import gleam/option.{type Option, None, Some}
import gleam/dynamic
import gleam/map
import gleam/otp/actor
import gleam/erlang/process.{type Subject}
import sprocket/internal/constants.{call_timeout}
import sprocket/context.{
  type Attribute, type ClientDispatcher, type ClientEventHandler, type Context,
  type EffectCleanup, type Element, type HandlerFn, type HookDependencies,
  type HookTrigger, type IdentifiableHandler, Callback, CallbackResult, Changed,
  Client, ClientHook, Context, Effect, Handler, IdentifiableHandler, OnMount,
  OnUpdate, Unchanged, WithDeps, compare_deps,
}
import sprocket/internal/exceptions.{throw_on_unexpected_hook_result}
import sprocket/internal/utils/unique
import sprocket/internal/logger

/// State Hook
/// ----------
/// Creates a state hook that can be used to manage state. The state hook will return
/// the current state and a setter function that can be used to update the state. Setting
/// the state will result in a re-render of the component.
pub fn state(
  ctx: Context,
  initial: a,
  cb: fn(Context, a, fn(a) -> Nil) -> #(Context, List(Element)),
) -> #(Context, List(Element)) {
  let Context(render_update: render_update, update_hook: update_hook, ..) = ctx

  let init_state = fn() {
    context.State(unique.cuid(ctx.cuid_channel), dynamic.from(initial))
  }

  let assert #(ctx, context.State(hook_id, value), _index) =
    context.fetch_or_init_hook(ctx, init_state)

  // create a dispatch function for updating the reducer's state and triggering a render update
  let setter = fn(value) -> Nil {
    update_hook(
      hook_id,
      fn(hook) {
        case hook {
          context.State(id, _) if id == hook_id ->
            context.State(id, dynamic.from(value))
          _ -> {
            // this should never happen and could be an indication that a hook is being
            // used incorrectly
            throw_on_unexpected_hook_result(hook)
          }
        }
      },
    )

    render_update()
  }

  cb(ctx, dynamic.unsafe_coerce(value), setter)
}

type Reducer(model, msg) =
  fn(model, msg) -> model

type StateOrDispatchReducer(model, msg) {
  Shutdown
  StateReducer(reply_with: Subject(model))
  DispatchReducer(r: Reducer(model, msg), m: msg)
}

/// Reducer Hook
/// ------------
/// Creates a reducer hook that can be used to manage state. The reducer hook will
/// return the current state of the reducer and a dispatch function that can be used
/// to update the reducer's state. Dispatching a message to the reducer will result
/// in a re-render of the component.
pub fn reducer(
  ctx: Context,
  initial: model,
  reducer: Reducer(model, msg),
  cb: fn(Context, model, fn(msg) -> Nil) -> #(Context, List(Element)),
) -> #(Context, List(Element)) {
  let Context(render_update: render_update, ..) = ctx

  let reducer_init = fn() {
    // creates an actor process for a reducer that handles two types of messages:
    //  1. StateReducer msg, which simply returns the state of the reducer
    //  2. DispatchReducer msg, which will update the reducer state when a dispatch is triggered
    let assert Ok(reducer_actor) =
      actor.start(
        initial,
        fn(message: StateOrDispatchReducer(model, msg), state: model) -> actor.Next(
          StateOrDispatchReducer(model, msg),
          model,
        ) {
          case message {
            Shutdown -> actor.Stop(process.Normal)

            StateReducer(reply_with) -> {
              process.send(reply_with, state)
              actor.continue(state)
            }

            DispatchReducer(r, m) -> {
              r(state, m)
              |> actor.continue()
            }
          }
        },
      )

    context.Reducer(
      unique.cuid(ctx.cuid_channel),
      dynamic.from(reducer_actor),
      fn() { process.send(reducer_actor, Shutdown) },
    )
  }

  let assert #(ctx, context.Reducer(_id, dyn_reducer_actor, _cleanup), _index) =
    context.fetch_or_init_hook(ctx, reducer_init)

  // we dont know what types of reducer messages a component will implement so the best
  // we can do is store the actors as dynamic and coerce them back when updating
  let reducer_actor = dynamic.unsafe_coerce(dyn_reducer_actor)

  // get the current state of the reducer
  let state = process.call(reducer_actor, StateReducer(_), call_timeout)

  // create a dispatch function for updating the reducer's state and triggering a render update
  let dispatch = fn(msg) -> Nil {
    actor.send(reducer_actor, DispatchReducer(r: reducer, m: msg))

    render_update()
  }

  cb(ctx, state, dispatch)
}

pub fn consumer(
  ctx: Context,
  key: String,
  cb: fn(Context, a) -> #(Context, List(Element)),
) -> #(Context, List(Element)) {
  let value = case map.get(ctx.providers, key) {
    Ok(v) -> {
      dynamic.unsafe_coerce(v)
    }
    _ -> {
      logger.error(
        "
        No provider found with key: " <> key <> "

        When using a consumer hook, you must include a parent provider with the same key.
        ",
      )

      panic
    }
  }

  cb(ctx, value)
}

/// Effect Hook
/// -----------
/// Creates an effect hook that will run the given effect function when the hook is
/// triggered. The effect function is memoized and recomputed based on the trigger type.
pub fn effect(
  ctx: Context,
  effect_fn: fn() -> EffectCleanup,
  trigger: HookTrigger,
  cb: fn(Context) -> #(Context, List(Element)),
) -> #(Context, List(Element)) {
  // define the initial effect function that will only run when the hook is first created
  let init = fn() {
    Effect(unique.cuid(ctx.cuid_channel), effect_fn, trigger, None)
  }

  // get the previous effect result, if one exists
  let #(ctx, Effect(id, _effect_fn, _trigger, prev), index) =
    context.fetch_or_init_hook(ctx, init)

  // update the effect hook, combining with the previous result
  let ctx =
    context.update_hook(ctx, Effect(id, effect_fn, trigger, prev), index)

  cb(ctx)
}

/// Memo Hook
/// ---------
/// Creates a memo hook that can be used to memoize the result of a function. The memo
/// hook will return the result of the function and will only recompute the result when
/// the dependencies change.
pub fn memo(
  ctx: Context,
  memo_fn: fn() -> a,
  trigger: HookTrigger,
  cb: fn(Context, a) -> #(Context, List(Element)),
) -> #(Context, List(Element)) {
  let #(ctx, context.Memo(id, current_memoized, prev), index) =
    context.fetch_or_init_hook(
      ctx,
      fn() {
        context.Memo(
          unique.cuid(ctx.cuid_channel),
          dynamic.from(memo_fn()),
          None,
        )
      },
    )

  let #(memoized, deps) =
    maybe_trigger_update(
      trigger,
      prev
      |> option.then(fn(prev) { prev.deps }),
      current_memoized,
      fn() { dynamic.from(memo_fn()) },
    )

  let ctx =
    context.update_hook(
      ctx,
      context.Memo(id, memoized, Some(context.MemoResult(deps))),
      index,
    )

  cb(ctx, dynamic.unsafe_coerce(memoized))
}

/// Callback Hook
/// -------------
/// Creates a callback that can be triggered from DOM event attributes. The callback
/// function will be called with the event payload. This hook ensures that the callback
/// identifier remains stable preventing unnecessary id changes across renders. The
/// callback function is memoized and recomputed based on the trigger type.
pub fn callback(
  ctx: Context,
  callback_fn: fn() -> Nil,
  trigger: HookTrigger,
  cb: fn(Context, fn() -> Nil) -> #(ctx, List(Element)),
) -> #(ctx, List(Element)) {
  let #(ctx, Callback(id, current_callback_fn, prev), index) =
    context.fetch_or_init_hook(
      ctx,
      fn() { Callback(unique.cuid(ctx.cuid_channel), callback_fn, None) },
    )

  let #(callback_fn, deps) =
    maybe_trigger_update(
      trigger,
      prev
      |> option.then(fn(prev) { prev.deps }),
      current_callback_fn,
      fn() { callback_fn },
    )

  let ctx =
    context.update_hook(
      ctx,
      Callback(id, callback_fn, Some(CallbackResult(deps))),
      index,
    )

  cb(ctx, callback_fn)
}

fn maybe_trigger_update(
  trigger: HookTrigger,
  prev: Option(HookDependencies),
  value: a,
  updater: fn() -> a,
) -> #(a, Option(HookDependencies)) {
  case trigger {
    // Only compute callback on the initial render. This is a convience for WithDeps([]).
    OnMount -> {
      #(updater(), Some([]))
    }

    // Recompute callback on every update
    OnUpdate -> {
      #(updater(), None)
    }

    // Only compute callback on the initial render and when the dependencies change
    WithDeps(deps) -> {
      case prev {
        Some(prev_deps) -> {
          case compare_deps(prev_deps, deps) {
            Changed(new_deps) -> #(updater(), Some(new_deps))
            Unchanged -> #(value, prev)
          }
        }

        // initial render
        None -> #(updater(), Some(deps))
      }
    }
  }
}

/// Handler Hook
/// -------------
/// Creates a handler callback that can be triggered from DOM event attributes. The callback
/// function will be called with the event payload. This hook ensures that the handler
/// identifier remains stable preventing unnecessary id changes across renders.
pub fn handler(
  ctx: Context,
  handler_fn: HandlerFn,
  cb: fn(Context, IdentifiableHandler) -> #(ctx, List(Element)),
) -> #(ctx, List(Element)) {
  let #(ctx, Handler(id, _handler_fn), index) =
    context.fetch_or_init_hook(
      ctx,
      fn() { Handler(unique.cuid(ctx.cuid_channel), handler_fn) },
    )

  let ctx = context.update_hook(ctx, Handler(id, handler_fn), index)

  cb(ctx, IdentifiableHandler(id, handler_fn))
}

/// Client Hook
/// -----------
/// Creates a client hook that can be used to facilitate communication with a client
/// (such as a web browser). The client hook functionality is defined by the client
/// and is typically used to send or receive messages to/from the client.
pub fn client(
  ctx: Context,
  name: String,
  handle_event: Option(ClientEventHandler),
  cb: fn(Context, fn() -> Attribute, ClientDispatcher) ->
    #(Context, List(Element)),
) -> #(Context, List(Element)) {
  // define the client hook initializer
  let init = fn() { Client(unique.cuid(ctx.cuid_channel), name, handle_event) }

  // get the existing client hook or initialize it
  let #(ctx, Client(id, _name, _handle_event), index) =
    context.fetch_or_init_hook(ctx, init)

  // update the effect hook, combining with the previous result
  let ctx = context.update_hook(ctx, Client(id, name, handle_event), index)

  let bind_hook_attr = fn() { ClientHook(id, name) }

  // callback to dispatch an event to the client
  let dispatch_event = fn(name: String, payload: Option(String)) {
    context.dispatch_event(ctx, id, name, payload)
  }

  cb(ctx, bind_hook_attr, dispatch_event)
}
