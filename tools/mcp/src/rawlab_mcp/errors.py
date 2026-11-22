class AdapterError(Exception):
    def __init__(self, message, code="invalid_argument", status=None):
        super().__init__(message)
        self.code, self.status = code, status
