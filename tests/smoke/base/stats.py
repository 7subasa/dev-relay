def mean(values):
    """平均を返す。空のリストでは ValueError を送出する。"""
    if not values:
        raise ValueError("values is empty")
    return sum(values) / len(values)
