# Flag checks per user

Evaluate the flag for the user (identity), so a 25% rollout means a stable 25% of users. Keep the old path as the default when Flagsmith is unreachable.

## Node.js (server, `flagsmith-nodejs`)

```js
import Flagsmith from 'flagsmith-nodejs'
const flagsmith = new Flagsmith({ environmentKey: process.env.FLAGSMITH_SERVER_KEY })

const flags = await flagsmith.getIdentityFlags(user.id)
const result = flags.isFeatureEnabled('new-checkout') ? newCheckout(cart) : oldCheckout(cart)
```

## Python (`flagsmith`)

```python
from flagsmith import Flagsmith
flagsmith = Flagsmith(environment_key=os.environ["FLAGSMITH_SERVER_KEY"])

flags = flagsmith.get_identity_flags(identifier=user.id)
result = new_checkout(cart) if flags.is_feature_enabled("new-checkout") else old_checkout(cart)
```

## Browser / React (`flagsmith`, `flagsmith/react`)

```js
import flagsmith from 'flagsmith'
await flagsmith.init({ environmentID: CLIENT_SIDE_KEY, identity: user.id })
if (flagsmith.hasFeature('new-checkout')) renderNewCheckout()
```

## Keys

A server-side key comes from `flagsmith environment key create <environment>`; the client-side key is the environment's API key (`flagsmith environment list`). Never put a server-side key in browser code.
