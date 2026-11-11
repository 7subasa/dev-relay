def mean(values):
    """平均を返す。空のリストでは ValueError を送出する。"""
    if not values:
        raise ValueError("values is empty")
    return sum(values) / len(values)


def median(values):
    """中央値を返す。"""
    ordered = sorted(values)
    return ordered[len(ordered) // 2]
