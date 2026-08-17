# @version ^0.3.7
# (c) Curve.Fi, 2023
# SafeMath Implementation of AMM Math for 3-coin Curve Cryptoswap Pools
#
# Unless otherwise agreed on, only contracts owned by Curve DAO or
# Swiss Stake GmbH are allowed to call this contract.

"""
@title CurveTricryptoMathOptimized
@license MIT
@author Curve.Fi
@notice Curve AMM Math for 3 unpegged assets (e.g. ETH, BTC, USD).
"""

N_COINS: constant(uint256) = 3
A_MULTIPLIER: constant(uint256) = 10000

MIN_GAMMA: constant(uint256) = 10**10
MAX_GAMMA: constant(uint256) = 5 * 10**16

MIN_A: constant(uint256) = N_COINS**N_COINS * A_MULTIPLIER / 100
MAX_A: constant(uint256) = N_COINS**N_COINS * A_MULTIPLIER * 1000

version: public(constant(String[8])) = "v2.0.0"


# ------------------------ AMM math functions --------------------------------


@external
@view
def get_y(
    _ANN: uint256, _gamma: uint256, x: uint256[N_COINS], _D: uint256, i: uint256
) -> uint256[2]:
    """
    @notice Calculate x[i] given other balances x[0..N_COINS-1] and invariant D.
    @dev ANN = A * N**N . AMM contract's A is actuall ANN.
    @param _ANN AMM.A() value.
    @param _gamma AMM.gamma() value.
    @param x Balances multiplied by prices and precisions of all coins.
    @param _D Invariant.
    @param i Index of coin to calculate y.
    """

    # Safety checks
    # 放大系数要在安全范围内
    assert _ANN > MIN_A - 1 and _ANN < MAX_A + 1, "dev: unsafe values A"
    assert _gamma > MIN_GAMMA - 1 and _gamma < MAX_GAMMA + 1, "dev: unsafe values gamma"
    # 总流动性 D 要在安全范围内， 不能小于 0.1, 也不能大于 一千万亿个代币
    assert _D > 10**17 - 1 and _D < 10**15 * 10**18 + 1, "dev: unsafe values D"

    for k in range(3):
        if k != i:
            frac: uint256 = x[k] * 10**18 / _D
            # 已知代币数量相对于总流动性 D， 不能少于 1%, 也不能大于 10000%, 也就是 100倍。
            assert frac > 10**16 - 1 and frac < 10**20 + 1, "dev: unsafe values x[i]"

    j: uint256 = 0
    k: uint256 = 0
    if i == 0:
        j = 1
        k = 2
    elif i == 1:
        j = 0
        k = 2
    elif i == 2:
        j = 0
        k = 1

    ANN: int256 = convert(_ANN, int256)
    gamma: int256 = convert(_gamma, int256)
    D: int256 = convert(_D, int256)
    x_j: int256 = convert(x[j], int256)
    x_k: int256 = convert(x[k], int256)

    # 【1. 构建一元三次方程】
    # 这里实际上是将 Curve V2 的复杂 AMM 不变量方程展开，
    # 整理成了一个标准的关于未知余额 y 的一元三次方程：ay^3 - by^2 + cy - d = 0
    """
        两种形式完全相等:
            ay^3 - by^2 + cy - d = 0
            
            -ay^3 + by^2 - cy + d = 0

        系数项 b 是负数。
        所以：
            y = t - (-b)/3a = t + b/3a   (注解: 1-2.md)
        代入一元三次方程，消去 y^2 项,  得到缺项三次方程:
            t^3 + pt + q = 0

        带入系数：
            B=b/a, C=c/a, D=d/a
        但是在这里的方程中， b和d 都有负号， 带入化简:  (注解: 1-2.md)
            p = (3ac - b^2) / (3a^2)
            q = (-2b^3 + 9abc - 27a^2d) / (27a^3)
              = (9abc - 2b^3 - 27a^2d) / (27a^3)
    """
    # 下方的 a, b, c, d 就是提取出来的各项初始系数。
    a: int256 = 10**36 / 27
    b: int256 = 10**36/9 + 2*10**18*gamma/27 - D**2/x_j*gamma**2*ANN/27**2/convert(A_MULTIPLIER, int256)/x_k
    c: int256 = 10**36/9 + gamma*(gamma + 4*10**18)/27 + gamma**2*(x_j+x_k-D)/D*ANN/27/convert(A_MULTIPLIER, int256)
    d: int256 = (10**18 + gamma)**2/27

    """
        如果在智能合约中直接计算 b^2, 由于 b 往往是一个极大的数字(包含代币精度 10^18 且多次乘法后可能高达 10^38),
        b^2 极易突破 EVM 10^77 的上限.

        为了避免直接计算 b^2, Curve 的数学家做了一个绝妙的等价变形。我们将 3ac - b^2 整体除以 b :
            (p 的子项) = 3ac - b^2 =  3ac/b - b

        这里的 abs 是为了忽略符号，因为我们只关心数值的真实大小。
    """
    d0: int256 = abs(3*a*c/b - b)

    # divider 和 additional_prec 用于精度缩放防溢出，属工程处理，不影响数学本质
    divider: int256 = 0
    if d0 > 10**48:
        divider = 10**30
    elif d0 > 10**44:
        divider = 10**26
    elif d0 > 10**40:
        divider = 10**22
    elif d0 > 10**36:
        divider = 10**18
    elif d0 > 10**32:
        divider = 10**14
    elif d0 > 10**28:
        divider = 10**10
    elif d0 > 10**24:
        divider = 10**6
    elif d0 > 10**20:
        divider = 10**2
    else:
        divider = 1

    """
        a 是“锚”：代码一开始就定义了 a: int256 = 10**36 / 27。它是一个写死的绝对常量, 体量永远保持在 10^34 级别，雷打不动。  
        b 是“脱缰的野马”: b 的计算公式里包含了 D**2/x_j 等大量与用户当前流动性和代币余额直接相关的动态变量。它可能极大，也可能极小。  
        c 和 d 是“陪跑的”：它们虽然也动态变化，但它们在后续卡尔丹公式里的危险系数不如 b 那么关键，且受 b 的制约。

        所以：
            如果 b 太小(abs(a) > abs(b))，就计算一个倍数，把 b 强行放大到 a 的规模.
            如果 b 太大(abs(b) > abs(a))，就计算一个倍数，把 b 强行按压到 a 的规模.

        至于对 a, c, d 也进行同等比例的乘除，纯粹是因为代数基本原则：为了保证方程的根不变，
        等号左边每一项必须同乘或同除同一个数。它们只是为了迁就 b 的缩放而被迫同步调整罢了。
    """
    additional_prec: int256 = 0
    if abs(a) > abs(b):
        additional_prec = abs(a) / abs(b)
        a = a * additional_prec / divider
        b = b * additional_prec / divider
        c = c * additional_prec / divider
        d = d * additional_prec / divider
    else:
        additional_prec = abs(b) / abs(a)
        """
            除完之后，新的 |b| 被强行压缩到了 |a| 的级别 (10^34),然后大家再统一除以 divider。
        """
        a = a / additional_prec / divider
        b = b / additional_prec / divider
        c = c / additional_prec / divider
        d = d / additional_prec / divider

    # 【2. 阶段 1.2 与阶段 2 映射：契尔恩豪斯变换与二次预解式】
    """
        把 p 的子项除以 b:
            △₀ = (3ac - b^2) / b

        把 q 的子项除以 b^²:
            △₁ = (9abc - 2b^3 - 27a^2d) / b^²

        就得出来了下面的 delta0 和 delta1, 它们是卡尔丹公式的核心判别式 Δ 的前置计算。
    """
    delta0: int256 = 3*a*c/b - b
    delta1: int256 = 9*a*c/b - 2*b - 27*a**2/b*d/b

    # 【3. 阶段 3 核心映射：提取判别式 Δ】
    # sqrt_arg 就是我们推导出的判别式核心 Δ = (q/2)^2 + (p/3)^3 经过代码缩放处理后的结果。

    """
        结合上面  △₀ 和 △₁ 的定义：
            p = b • △₀ / 3a²
            q = b² • △₁ / 27a³

        带入判别式化简：
            b⁴/2916a⁶ • (△₁² + 4△₀³/b)

        就是下面的 sqrt_arg 计算。
    """
    sqrt_arg: int256 = delta1**2 + 4*delta0**2/b*delta0
    sqrt_val: int256 = 0
    # 【4. 高阶安全审计视角：不可约情形 (Casus Irreducibilis) 与 EVM 的死穴】
    if sqrt_arg > 0:
        # 理论真相：当 Δ > 0（即 sqrt_arg > 0）时，方程有 1 个实根，2 个复数根。
        # 硬件适配：此时对正数开平方产生的是一个普通的实数，没有任何虚数 i 参与计算。
        # 工程直达：EVM 虽然只有正整数，但可以放心调用 isqrt（整数开方）继续往下算卡尔丹的解析解。
        sqrt_val = convert(isqrt(convert(sqrt_arg, uint256)), int256)
    else:
        # 噩梦降临：当 Δ <= 0 时，意味着存在 3 个完美的实数解。
        # 卡尔丹的死结：但计算过程被“锁死”了，此时强行使用卡尔丹公式必须对负数开根号（产生虚数 i）。
        # 降级回退机制：EVM 绝对不可能理解虚数，一旦触发负数开根号，整个合约就会崩溃 Revert、锁死资金。
        # 因此，代码极具智慧地在此处“弃用”了卡尔丹公式（解析解），进入 else 分支！
        # 直接 fallback 调用 self._newton_y（牛顿迭代法），通过纯粹的加减乘除避开虚数盲区。
        return [self._newton_y(_ANN, _gamma, x, _D, i), 0]

    # 【5. 阶段 2.3 与阶段 3 映射：求解卡尔丹公式的立方根 u 和 v】
    """
        求 ∛b :
        如果 b 是正数，直接开方；如果 b 是负数，就先取它的绝对值 (-b),
        当作正数交给 _cbrt 算出结果，最后再在外面手动套上一个负号
    """
    b_cbrt: int256 = 0
    if b >= 0:
        b_cbrt = convert(self._cbrt(convert(b, uint256)), int256)
    else:
        b_cbrt = -convert(self._cbrt(convert(-b, uint256)), int256)

    second_cbrt: int256 = 0
    # 这一步计算的就是卡尔丹公式里核心的开立方根结构：v = ∛(-q/2 - √Δ)
    """
        计算判别式中 (-q/2):
            -q/2 = -(b²• △₁)/54a³ 

        sqrt_val = √sqrt_arg

        之前只计算出了括号内的 sqrt_arg, 真正的判别式包括 b⁴/2916a⁶ :

        △ = b⁴/2916a⁶ • (sqrt_val)²

        卡尔丹公式需要用到的是 √△ :
            √△ = b²/54a³ • sqrt_val

        (-v|-u)  = ∛(-q/2 + √△) 
            = ∛-(△₁ • b²/54a³) + (b²/54a³ • sqrt_val) 

        把公因数提到外部:
            ∛(b²/54a³ • (-△₁ + sqrt_val))

        我们需要对 -v³  开立方， 54 的一半 27 可以开立方， 所以：
            (-v|-u) = ∛(b²/27a³ • (-△₁ + sqrt_val)/2)

        对等式两边分别开立方：
            ∛(b²/27a³) = b^(⅔)/3a
        b 在前面已经开立方了， 所以 b_cbrt*b_cbrt 就是 b^(⅔)。

        右边那一半无法化简，只能交给 EVM 去硬算, 完美对应 second_cbrt 的代码实现.
    """
    if delta1 > 0:
        # △₁ 大于 0 时，计算的就是 -3a•v
        second_cbrt = convert(self._cbrt(convert((delta1 + sqrt_val), uint256)/2), int256)
    else:
        # △₁ 小于 0 时，计算的就是 -3a•u
        second_cbrt = -convert(self._cbrt(convert(-(delta1 - sqrt_val), uint256)/2), int256)

    # 【6. 回归原点：撤销韦达替换 (t = u+v) 与契尔恩豪斯平移 (x = t + B/3)】
    """
        计算出 v :
            b^(⅔) • (-△₁ + sqrt_val)/2

        这里算出的就是 3a • (-v|-u) , 也就是 3a•v 或者 3a•u, 取决于 delta1 的正负号。

        这里的 b_cbrt 和 second_cbrt 都是经过了缩放处理的， 需要除以 10^18 来还原回原来的数值。
    """
    C1: int256 = b_cbrt*b_cbrt/10**18*second_cbrt/10**18

    # 这一步对应了平移的逆向操作，把 t 还原回 x（x = t + B/3）。
    """
        利用了韦达定理的一个隐藏属性: u•v = -p/3 ,

         已知:
            y=t+b/3a , 
         消除分母, 两边同乘 3a (记住这个框架，这是我们最终要组装的目标):
            3a•y = 3a•t + b

        根据韦达定理, t = u + v, 所以:
            3a•y = 3a•(u+v) + b 
        展开： 
            3a•y = 3a•u+ 3a•v + b
        
        现在的任务很明确：我们要用已知变量找到 3a•u 和 3a•v。

        根据前面的计算，我们已经得到了 3a•v = -C1。

        推导 p 与 delta0 的关系：
            3uv = -p
            p = (3ac -b²)/3a²

            delta0 = 3ac - b² / b
            3ac - b² = delta0 • b
        把这个关系带回 p 的等式中:
            p = delta0 • b / 3a²

        利用约束条件求出 3a•u:
            3uv = -p
            uv = -p/3
            uv = -(delta0 • b / 9a²)

        两边同乘 9a²:
            9a²•uv = -delta0 • b
            3au•3av = -delta0 • b

        把我们在之前得到的 3a•v = -C1 代入上式：
            3au•(-C1) = -delta0 • b
            3au = delta0 • b / C1
        
        终极大组装:
            3a•y = 3a•u + 3a•v + b
        带入 3au 和 3av:
            3a•y = b + delta0 • b / C1 - C1

        这里除以 3, 返回时再除以 a, 就得到了最终的 y 根。
    """
    root_K0: int256 = (b + b*delta0/C1 - C1)/3

    # 最终结合代币精度和 AMM 的 D 值进行换算，得出真正可以用于转账的精确余额！
    root: uint256 = convert(D*D/27/x_k*D/x_j*root_K0/a, uint256)

    return [
        root,
        convert(10**18*root_K0/a, uint256)
    ]


@internal
@view
def _newton_y(
    ANN: uint256, gamma: uint256, x: uint256[N_COINS], D: uint256, i: uint256
) -> uint256:

    # Calculate x[i] given A, gamma, xp and D using newton's method.
    # This is the original method; get_y replaces it, but defaults to
    # this version conditionally.

    # Safety checks
    assert ANN > MIN_A - 1 and ANN < MAX_A + 1, "dev: unsafe values A"
    assert gamma > MIN_GAMMA - 1 and gamma < MAX_GAMMA + 1, "dev: unsafe values gamma"
    assert D > 10**17 - 1 and D < 10**15 * 10**18 + 1, "dev: unsafe values D"

    for k in range(3):
        if k != i:
            frac: uint256 = x[k] * 10**18 / D
            assert frac > 10**16 - 1 and frac < 10**20 + 1, "dev: unsafe values x[i]"

    y: uint256 = D / N_COINS
    K0_i: uint256 = 10**18
    S_i: uint256 = 0

    x_sorted: uint256[N_COINS] = x
    x_sorted[i] = 0
    x_sorted = self._sort(x_sorted)  # From high to low

    convergence_limit: uint256 = max(max(x_sorted[0] / 10**14, D / 10**14), 100)
    for j in range(2, N_COINS + 1):
        _x: uint256 = x_sorted[N_COINS - j]
        y = y * D / (_x * N_COINS)  # Small _x first
        S_i += _x
    for j in range(N_COINS - 1):
        K0_i = K0_i * x_sorted[j] * N_COINS / D  # Large _x first

    # initialise variables:
    diff: uint256 = 0
    y_prev: uint256 = 0
    K0: uint256 = 0
    S: uint256 = 0
    _g1k0: uint256 = 0
    mul1: uint256 = 0
    mul2: uint256 = 0
    yfprime: uint256 = 0
    _dyfprime: uint256 = 0
    fprime: uint256 = 0
    y_minus: uint256 = 0
    y_plus: uint256 = 0

    for j in range(255):

        y_prev = y

        K0 = K0_i * y * N_COINS / D
        S = S_i + y

        _g1k0 = gamma + 10**18
        if _g1k0 > K0:
            _g1k0 = _g1k0 - K0 + 1
        else:
            _g1k0 = K0 - _g1k0 + 1

        mul1 = 10**18 * D / gamma * _g1k0 / gamma * _g1k0 * A_MULTIPLIER / ANN

        # 2*K0 / _g1k0
        mul2 = 10**18 + (2 * 10**18) * K0 / _g1k0

        yfprime = 10**18 * y + S * mul2 + mul1
        _dyfprime = D * mul2
        if yfprime < _dyfprime:
            y = y_prev / 2
            continue
        else:
            yfprime -= _dyfprime

        fprime = yfprime / y

        # y -= f / f_prime;  y = (y * fprime - f) / fprime
        y_minus = mul1 / fprime
        y_plus = (
            yfprime + 10**18 * D
        ) / fprime + y_minus * 10**18 / K0
        y_minus += 10**18 * S / fprime

        if y_plus < y_minus:
            y = y_prev / 2
        else:
            y = y_plus - y_minus

        if y > y_prev:
            diff = y - y_prev
        else:
            diff = y_prev - y

        if diff < max(convergence_limit, y / 10**14):
            frac: uint256 = y * 10**18 / D
            assert (frac > 10**16 - 1) and (frac < 10**20 + 1), "dev: unsafe value for y"
            return y

    raise "Did not converge"


@external
@view
def newton_D(
    ANN: uint256,
    gamma: uint256,
    x_unsorted: uint256[N_COINS],
    K0_prev: uint256 = 0,
) -> uint256:
    """
    @notice Finding the invariant via newtons method using good initial guesses.
    @dev ANN is higher by the factor A_MULTIPLIER
    @dev ANN is already A * N**N
    @param ANN the A * N**N value
    @param gamma the gamma value
    @param x_unsorted the array of coin balances (not sorted)
    @param K0_prev apriori for newton's method derived from get_y_int. Defaults
                    to zero (no apriori)
    """
    x: uint256[N_COINS] = self._sort(x_unsorted)
    assert x[0] < max_value(uint256) / 10**18 * N_COINS**N_COINS, "dev: out of limits"

    S: uint256 = 0
    for x_i in x:
        S += x_i

    D: uint256 = 0
    if K0_prev == 0:
        D = N_COINS * self._geometric_mean(x)
    else:
        if S > 10**36:
            D = self._cbrt(x[0]*x[1]/10**36*x[2]/K0_prev*27*10**12)
        elif S > 10**24:
            D = self._cbrt(x[0]*x[1]/10**24*x[2]/K0_prev*27*10**6)
        else:
            D = self._cbrt(x[0]*x[1]/10**18*x[2]/K0_prev*27)

    # initialise variables:
    diff: uint256 = 0
    K0: uint256 = 0
    _g1k0: uint256 = 0
    mul1: uint256 = 0
    mul2: uint256 = 0
    neg_fprime: uint256 = 0
    D_plus: uint256 = 0
    D_minus: uint256 = 0

    for i in range(255):
        D_prev: uint256 = D

        K0 = 10**18 * x[0] * N_COINS / D * x[1] * N_COINS / D * x[2] * N_COINS / D

        _g1k0 = unsafe_add(gamma, 10**18)
        if _g1k0 > K0:
            _g1k0 = unsafe_add(unsafe_sub(_g1k0, K0), 1)
        else:
            _g1k0 = unsafe_add(unsafe_sub(K0, _g1k0), 1)

        # D / (A * N**N) * _g1k0**2 / gamma**2
        mul1 = 10**18 * D / gamma * _g1k0 / gamma * _g1k0 * A_MULTIPLIER / ANN

        # 2*N*K0 / _g1k0
        mul2 = (2 * 10**18) * N_COINS * K0 / _g1k0

        # neg_fprime: uint256 = (S + S * mul2 / 10**18) + mul1 * N_COINS / K0 - mul2 * D / 10**18
        neg_fprime = (S + S * mul2 / 10**18) + mul1 * N_COINS / K0 - mul2 * D / 10**18

        # D -= f / fprime
        # D * (neg_fprime + S) / neg_fprime
        D_plus = D * (neg_fprime + S) / neg_fprime
        # D*D / neg_fprime
        D_minus = D*D / neg_fprime

        if 10**18 > K0:
            # D_minus += D * (mul1 / neg_fprime) / 10**18 * (10**18 - K0) / K0
            D_minus += D * (mul1 / neg_fprime) / 10**18 * (10**18 - K0) / K0
        else:
            # D_minus -= D * (mul1 / neg_fprime) / 10**18 * (K0 - 10**18) / K0
            D_minus -= D * (mul1 / neg_fprime) / 10**18 * (K0 - 10**18) / K0

        if D_plus > D_minus:
            D = D_plus - D_minus
        else:
            D = (D_minus - D_plus) / 2

        if D > D_prev:
            diff = unsafe_sub(D, D_prev)
        else:
            diff = unsafe_sub(D_prev, D)

        # Could reduce precision for gas efficiency here:
        if unsafe_mul(diff, 10**14) < max(10**16, D):

            # Test that we are safe with the next newton_y
            for _x in x:
                frac: uint256 = _x * 10**18 / D
                assert (frac > 10**16 - 1) and (frac < 10**20 + 1)  # dev: unsafe values x[i]

            return D

    raise "Did not converge"


@external
@view
def get_p(
    _xp: uint256[N_COINS],
    _D: uint256,
    _A_gamma: uint256[2],
) -> uint256[N_COINS-1]:
    """
    @notice Calculates dx/dy.
    @dev Output needs to be multiplied with price_scale to get the actual value.
    @param _xp Balances of the pool.
    @param _D Current value of D.
    @param _A_gamma Amplification coefficient and gamma.
    """

    assert _D > 10**17 - 1 and _D < 10**15 * 10**18 + 1, "dev: unsafe values D"

    xp: int256[N_COINS] = empty(int256[N_COINS])
    A_gamma: int256[2] = empty(int256[2])

    D: int256 = convert(_D, int256)
    for i in range(N_COINS):
        xp[i] = convert(_xp[i], int256)
        if i < N_COINS-1:
            A_gamma[i] = convert(_A_gamma[i], int256)

    A: int256 = A_gamma[0]
    gamma: int256 = A_gamma[1]
    x1: int256 = xp[0]
    x2: int256 = xp[1]
    x3: int256 = xp[2]

    """
        Aγ²(γ + 1) - (γ + 1)³

        化简:
            (1+γ)•[-1+γ(-2-γ+Aγ)] = Aγ²(γ + 1) - (γ + 1)³
    """
    s1: int256 = (10**18 + gamma)*(-10**18 + gamma*(-2*10**18 + (-10**18 + 10**18*A/10000)*gamma/10**18)/10**18)/10**18
    """
        [3(γ + 1)² + Aγ²]k

        3•27 = 81
        代码是: 1 + γ(2 + γ + Aγ/3) = (γ + 1)² + Aγ²/3 
        把它与外面的 3 相乘就得到了 3(γ + 1)² + Aγ²
        再结合外面的 27 和代币乘积:
            27[3(γ + 1)² + Aγ²]•(k/27) = 3[(γ + 1)² + Aγ²]k
    """
    s2: int256 = 81*(10**18 + gamma*(2*10**18 + gamma + 10**18*9*A/27/10000*gamma/10**18)/10**18)*x1/D*x2/D*x3/D
    """
        3(γ + 1)k²

        2187 = 3•729 = 3•27²
        代数本质: 3•27²•(γ + 1)•(x₁x₂x₃/D³)² , 带入 k/27 :
            3•27²•(γ + 1)•(k/27)²
    """
    s3: int256 = 2187*(10**18 + gamma)*x1/D*x1/D*x2/D*x2/D*x3/D*x3/D
    """
        k³
        (27x₁x₂x₃/D³)³ = K/27 这里除以的是 n^n = 3³ = 27
        19683 = 27³

        s4 代数本质: 19683•(x₁x₂x₃/D³)³ = 19683•(k/27)³ = k³
    """
    s4: int256 = 10**18*19683*x1/D*x1/D*x1/D*x2/D*x2/D*x2/D*x3/D*x3/D*x3/D

    # a = (k - γ - 1)³ + Aγ²(k + γ + 1)   
    # a = k³ - 3(γ + 1)k² + [3(γ + 1)² + Aγ²]k + [Aγ²(γ + 1) - (γ + 1)³]
    a: int256 = s1 + s2 + s4 - s3
    # b = Aγ²k/D
    # 729•A•(x₁x₂x₃)•γ²/27•D³•D = 27•A•γ²•(x₁x₂x₃/D³)/D =  = Aγ²k/D
    b: int256 = 10**18*729*A*x1/D*x2/D*x3/D*gamma**2/D/27/10000
    # c = Aγ²(γ + 1)/D
    c: int256 = 27*A*gamma**2*(10**18 + gamma)/D/27/10000

    """
        恒等式化简后:
            F = Aγ²K(S - 1)+(K - 1)(K - γ - 1)² = 0
        对 X_i 求偏导 ∂F/∂X_i , 利用链式法则:
            Aγ²K/D + (K - γ - 1)(2K² - K - γ - 1)/X_i
        同一个缩放因子，比值是不变的 (K - γ - 1)/D :
            F_i' = (K - γ - 1)²(2K² - K - γ - 1)/K•X_i + Aγ²(K - γ - 1 )/D

        为了计算 F_i' 巧妙地构造了三个宏观参数 a, b, c , 上面计算的就是。
        为了去掉分母中的 X_i, 两边同乘 X_i :
        
            f(x_i) = a - (b+c)S_x + (b-c)x_i
            f(x_i) = x_i•F_i'
    """
    return [
        self._get_dxdy(x2, x1, x3, a, b, c),
        self._get_dxdy(x3, x1, x2, a, b, c),
    ]

@internal
@view
def _get_dxdy(
    x1: int256,
    x2: int256,
    x3: int256,
    a: int256,
    b: int256,
    c: int256,
) -> uint256:

    p: int256 = (
        """
            a - b(X₂ + X₃) - C(2X₁ + X₂ + X₃)

            已知: S_x = 2X₁ + X₂ + X₃
            包含 b 的项写成:       -b(S_x - X₁)
            包含 c 的项写成:       -c(X₁ + S_x)

            全部带入展开:
                a  - b(S_x - X₁) - c(X₁ + S_x) = f(x_i)
            这里就是:   X₂•f(x₁)

            对于代币 1: f(X₁) = X₁•F'₁
            对于代币 2: f(X₂) = X₂•F'₂
        """
        (10**18*x2*( 10**18*a - b*(x2 + x3)/10**18 - c*(2*x1 + x2 + x3)/10**18))
        /
        """
            这里构造是: -x₁•f(x₂)

            p = X₂•f(x₁) / -x₁•f(x₂)
            根据之前的结论:     f(x_i) = x_i•F_i'

            p = X₂•X₁•F'₁ / -X₁•X₂•F'₂ = -(F'₁/F'₂)
            -p = F'₁/F'₂
        """
        (x1*(-10**18*a + b*(x1 + x3)/10**18 + c*(x1 + 2*x2 + x3)/10**18))
    )

    return convert(-p, uint256)


# --------------------------- Math Utils -------------------------------------


@external
@view
def cbrt(x: uint256) -> uint256:
    """
    @notice Calculate the cubic root of a number in 1e18 precision
    @dev Consumes around 1500 gas units
    @param x The number to calculate the cubic root of
    """
    return self._cbrt(x)


@external
@view
def geometric_mean(_x: uint256[3]) -> uint256:
    """
    @notice Calculate the geometric mean of a list of numbers in 1e18 precision.
    @param _x list of 3 numbers to sort
    """
    return self._geometric_mean(_x)


@external
@view
def reduction_coefficient(x: uint256[N_COINS], fee_gamma: uint256) -> uint256:
    """
    @notice Calculates the reduction coefficient for the given x and fee_gamma
    @dev This method is used for calculating fees.
    @param x The x values
    @param fee_gamma The fee gamma value
    """
    return self._reduction_coefficient(x, fee_gamma)


@external
@view
def wad_exp(_power: int256) -> uint256:
    """
    @notice Calculates the e**x with 1e18 precision
    @param _power The number to calculate the exponential of
    """
    return self._exp(_power)


@internal
@pure
def _reduction_coefficient(x: uint256[N_COINS], fee_gamma: uint256) -> uint256:

    # fee_gamma / (fee_gamma + (1 - K))
    # where
    # K = prod(x) / (sum(x) / N)**N
    # (all normalized to 1e18)

    K: uint256 = 10**18
    S: uint256 = x[0] + x[1] + x[2]

    # Could be good to pre-sort x, but it is used only for dynamic fee
    for x_i in x:
        K = K * N_COINS * x_i / S

    if fee_gamma > 0:
        K = fee_gamma * 10**18 / (fee_gamma + 10**18 - K)

    return K


@internal
@pure
def _exp(_power: int256) -> uint256:

    # This implementation is borrowed from transmissions11 and Remco Bloemen:
    # https://github.com/transmissions11/solmate/blob/main/src/utils/SignedWadMath.sol
    # Method: wadExp

    if _power <= -42139678854452767551:
        return 0

    if _power >= 135305999368893231589:
        raise "exp overflow"

    x: int256 = unsafe_div(unsafe_mul(_power, 2**96), 10**18)

    k: int256 = unsafe_div(
        unsafe_add(
            unsafe_div(unsafe_mul(x, 2**96), 54916777467707473351141471128),
            2**95,
        ),
        2**96,
    )
    x = unsafe_sub(x, unsafe_mul(k, 54916777467707473351141471128))

    y: int256 = unsafe_add(x, 1346386616545796478920950773328)
    y = unsafe_add(
        unsafe_div(unsafe_mul(y, x), 2**96), 57155421227552351082224309758442
    )
    p: int256 = unsafe_sub(unsafe_add(y, x), 94201549194550492254356042504812)
    p = unsafe_add(unsafe_div(unsafe_mul(p, y), 2**96), 28719021644029726153956944680412240)
    p = unsafe_add(unsafe_mul(p, x), (4385272521454847904659076985693276 * 2**96))

    q: int256 = x - 2855989394907223263936484059900
    q = unsafe_add(unsafe_div(unsafe_mul(q, x), 2**96), 50020603652535783019961831881945)
    q = unsafe_sub(unsafe_div(unsafe_mul(q, x), 2**96), 533845033583426703283633433725380)
    q = unsafe_add(unsafe_div(unsafe_mul(q, x), 2**96), 3604857256930695427073651918091429)
    q = unsafe_sub(unsafe_div(unsafe_mul(q, x), 2**96), 14423608567350463180887372962807573)
    q = unsafe_add(unsafe_div(unsafe_mul(q, x), 2**96), 26449188498355588339934803723976023)

    return shift(
        unsafe_mul(
            convert(unsafe_div(p, q), uint256),
            3822833074963236453042738258902158003155416615667
        ),
        unsafe_sub(k, 195),
    )


@internal
@pure
def _log2(x: uint256) -> int256:

    # Compute the binary logarithm of `x`

    # This was inspired from Stanford's 'Bit Twiddling Hacks' by Sean Eron Anderson:
    # https://graphics.stanford.edu/~seander/bithacks.html#IntegerLog
    #
    # More inspiration was derived from:
    # https://github.com/transmissions11/solmate/blob/main/src/utils/SignedWadMath.sol

    log2x: int256 = 0
    if x > 340282366920938463463374607431768211455:
        log2x = 128
    if unsafe_div(x, shift(2, log2x)) > 18446744073709551615:
        log2x = log2x | 64
    if unsafe_div(x, shift(2, log2x)) > 4294967295:
        log2x = log2x | 32
    if unsafe_div(x, shift(2, log2x)) > 65535:
        log2x = log2x | 16
    if unsafe_div(x, shift(2, log2x)) > 255:
        log2x = log2x | 8
    if unsafe_div(x, shift(2, log2x)) > 15:
        log2x = log2x | 4
    if unsafe_div(x, shift(2, log2x)) > 3:
        log2x = log2x | 2
    if unsafe_div(x, shift(2, log2x)) > 1:
        log2x = log2x | 1

    return log2x


@internal
@pure
def _cbrt(x: uint256) -> uint256:

    xx: uint256 = 0
    # ---------------- 1. 数值缩放 (保证计算精度) ----------------
    # 这里的魔法数字 115792089237316195423570985008687907853269 是 (2**256 - 1) / 10**18 的近似值。
    # 目标是尽量将输入 x 放大，以便在整数运算中保留更多的小数精度，但又要防止溢出。
    if x >= 115792089237316195423570985008687907853269 * 10**18:
        xx = x
    elif x >= 115792089237316195423570985008687907853269:
        xx = unsafe_mul(x, 10**18)
    else:
        xx = unsafe_mul(x, 10**36)

    """
        最高位作为猜测初始值， 准确性已经很高。
    """
    log2x: int256 = self._log2(xx)

    # When we divide log2x by 3, the remainder is (log2x % 3).
    # So if we just multiply 2**(log2x/3) and discard the remainder to calculate our
    # guess, the newton method will need more iterations to converge to a solution,
    # since it is missing that precision. It's a few more calculations now to do less
    # calculations later:
    # pow = log2(x) // 3
    # remainder = log2(x) % 3
    # initial_guess = 2 ** pow * cbrt(2) ** remainder
    # substituting -> 2 = 1.26 ≈ 1260 / 1000, we get:
    #
    # initial_guess = 2 ** pow * 1260 ** remainder // 1000 ** remainder

    remainder: uint256 = convert(log2x, uint256) % 3
    a: uint256 = unsafe_div(
        unsafe_mul(
            # 2^(log2x / 3)   整数部分
            pow_mod256(2, unsafe_div(convert(log2x, uint256), 3)),  # <- pow   
            """
                2的立方根大概是 1.2599
                1260 / 1000 = 1.26, 这是一个近似值。
                1260 ** remainder / 1000 ** remainder
            """
            pow_mod256(1260, remainder),
        ),
        pow_mod256(1000, remainder),
    )

    # Because we chose good initial values for cube roots, 7 newton raphson iterations
    # are just about sufficient. 6 iterations would result in non-convergences, and 8
    # would be one too many iterations. Without initial values, the iteration count
    # can go up to 20 or greater. The iterations are unrolled. This reduces gas costs
    # but takes up more bytecode:
    """
        F(0) = a^3 - xx = 0 这是判别式， 而不是成立的方程。
        根据牛顿迭代：
                a_{n+1} = a_n - F(a_n) / F'(a_n)
        推导出迭代公式：
                (2 * a_n + xx / (a_n^2)) / 3
    """
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)
    a = unsafe_div(unsafe_add(unsafe_mul(2, a), unsafe_div(xx, unsafe_mul(a, a))), 3)

    """
        在合约中, 所有值都是以 1e18 的精度存储的。

        传进来的是 x • 10^18 , 所以我们要开立方的是 x/10^18

        目标值(N) = ³√(x/10^18) • 10^18 
                = ³√(x) • 10^18 / 10^6
                = ³√(x) • 10^12

        这就是为什么最后要补贴返回值的精度。
        大值之前没办法补，再补就溢出了。
    """
    if x >= 115792089237316195423570985008687907853269 * 10**18:
        return a * 10**12
    elif x >= 115792089237316195423570985008687907853269:
        return a * 10**6

    return a


@internal
@pure
def _sort(unsorted_x: uint256[3]) -> uint256[3]:

    # Sorts a three-array number in a descending order:

    x: uint256[N_COINS] = unsorted_x
    temp_var: uint256 = x[0]
    if x[0] < x[1]:
        x[0] = x[1]
        x[1] = temp_var
    if x[0] < x[2]:
        temp_var = x[0]
        x[0] = x[2]
        x[2] = temp_var
    if x[1] < x[2]:
        temp_var = x[1]
        x[1] = x[2]
        x[2] = temp_var

    return x


@internal
@view
def _geometric_mean(_x: uint256[3]) -> uint256:

    # calculates a geometric mean for three numbers.

    prod: uint256 = _x[0] * _x[1] / 10**18 * _x[2] / 10**18
    assert prod > 0

    return self._cbrt(prod)



@internal
@pure
def _snekmate_mul_div(
    x: uint256, y: uint256, denominator: uint256, roundup: bool
) -> uint256:
    """
    @notice Calculates "(x * y) / denominator" in 512-bit precision,
         following the selected rounding direction.
    @dev This implementation is derived from Snekmate, which is authored
         by pcaversaccio (Snekmate), distributed under the AGPL-3.0 license.
         https://github.com/pcaversaccio/snekmate
    @dev The implementation is inspired by Remco Bloemen's
         implementation under the MIT license here:
         https://xn--2-umb.com/21/muldiv.
         Furthermore, the rounding direction design pattern is
         inspired by OpenZeppelin's implementation here:
         https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/Math.sol.
    @param x The 32-byte multiplicand.
    @param y The 32-byte multiplier.
    @param denominator The 32-byte divisor.
    @param roundup The Boolean variable that specifies whether
           to round up or not. The default `False` is round down.
    @return uint256 The 32-byte calculation result.
    """
    # Handle division by zero.
    assert denominator != empty(uint256), "Math: mul_div division by zero"

    # 512-bit multiplication "[prod1 prod0] = x * y".
    # Compute the product "mod 2**256" and "mod 2**256 - 1".
    # Then use the Chinese Remainder theorem to reconstruct
    # the 512-bit result. The result is stored in two 256-bit
    # variables, where: "product = prod1 * 2**256 + prod0".
    mm: uint256 = uint256_mulmod(x, y, max_value(uint256))
    # The least significant 256 bits of the product.
    prod0: uint256 = unsafe_mul(x, y)
    # The most significant 256 bits of the product.
    prod1: uint256 = empty(uint256)

    if (mm < prod0):
        prod1 = unsafe_sub(unsafe_sub(mm, prod0), 1)
    else:
        prod1 = unsafe_sub(mm, prod0)

    # Handling of non-overflow cases, 256 by 256 division.
    if (prod1 == empty(uint256)):
        if (roundup and uint256_mulmod(x, y, denominator) != empty(uint256)):
            # Calculate "ceil((x * y) / denominator)". The following
            # line cannot overflow because we have the previous check
            # "(x * y) % denominator != 0", which accordingly rules out
            # the possibility of "x * y = 2**256 - 1" and `denominator == 1`.
            return unsafe_add(unsafe_div(prod0, denominator), 1)
        else:
            return unsafe_div(prod0, denominator)

    # Ensure that the result is less than 2**256. Also,
    # prevents that `denominator == 0`.
    assert denominator > prod1, "Math: mul_div overflow"

    #######################
    # 512 by 256 Division #
    #######################

    # Make division exact by subtracting the remainder
    # from "[prod1 prod0]". First, compute remainder using
    # the `uint256_mulmod` operation.
    remainder: uint256 = uint256_mulmod(x, y, denominator)

    # Second, subtract the 256-bit number from the 512-bit
    # number.
    if (remainder > prod0):
        prod1 = unsafe_sub(prod1, 1)
    prod0 = unsafe_sub(prod0, remainder)

    # Factor powers of two out of the denominator and calculate
    # the largest power of two divisor of denominator. Always `>= 1`,
    # unless the denominator is zero (which is prevented above),
    # in which case `twos` is zero. For more details, please refer to:
    # https://cs.stackexchange.com/q/138556.

    # The following line does not overflow because the denominator
    # cannot be zero at this stage of the function.
    twos: uint256 = denominator & (unsafe_add(~denominator, 1))
    # Divide denominator by `twos`.
    denominator_div: uint256 = unsafe_div(denominator, twos)
    # Divide "[prod1 prod0]" by `twos`.
    prod0 = unsafe_div(prod0, twos)
    # Flip `twos` such that it is "2**256 / twos". If `twos` is zero,
    # it becomes one.
    twos = unsafe_add(unsafe_div(unsafe_sub(empty(uint256), twos), twos), 1)

    # Shift bits from `prod1` to `prod0`.
    prod0 |= unsafe_mul(prod1, twos)

    # Invert the denominator "mod 2**256". Since the denominator is
    # now an odd number, it has an inverse modulo 2**256, so we have:
    # "denominator * inverse = 1 mod 2**256". Calculate the inverse by
    # starting with a seed that is correct for four bits. That is,
    # "denominator * inverse = 1 mod 2**4".
    inverse: uint256 = unsafe_mul(3, denominator_div) ^ 2

    # Use Newton-Raphson iteration to improve accuracy. Thanks to Hensel's
    # lifting lemma, this also works in modular arithmetic by doubling the
    # correct bits in each step.
    inverse = unsafe_mul(inverse, unsafe_sub(2, unsafe_mul(denominator_div, inverse))) # Inverse "mod 2**8".
    inverse = unsafe_mul(inverse, unsafe_sub(2, unsafe_mul(denominator_div, inverse))) # Inverse "mod 2**16".
    inverse = unsafe_mul(inverse, unsafe_sub(2, unsafe_mul(denominator_div, inverse))) # Inverse "mod 2**32".
    inverse = unsafe_mul(inverse, unsafe_sub(2, unsafe_mul(denominator_div, inverse))) # Inverse "mod 2**64".
    inverse = unsafe_mul(inverse, unsafe_sub(2, unsafe_mul(denominator_div, inverse))) # Inverse "mod 2**128".
    inverse = unsafe_mul(inverse, unsafe_sub(2, unsafe_mul(denominator_div, inverse))) # Inverse "mod 2**256".

    # Since the division is now exact, we can divide by multiplying
    # with the modular inverse of the denominator. This returns the
    # correct result modulo 2**256. Since the preconditions guarantee
    # that the result is less than 2**256, this is the final result.
    # We do not need to calculate the high bits of the result and
    # `prod1` is no longer necessary.
    result: uint256 = unsafe_mul(prod0, inverse)

    if (roundup and uint256_mulmod(x, y, denominator) != empty(uint256)):
        # Calculate "ceil((x * y) / denominator)". The following
        # line uses intentionally checked arithmetic to prevent
        # a theoretically possible overflow.
        result += 1

    return result
