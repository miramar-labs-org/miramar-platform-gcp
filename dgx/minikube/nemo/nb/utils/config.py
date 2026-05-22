from omegaconf import OmegaConf
OmegaConf.register_new_resolver("merge", lambda *args : OmegaConf.merge(*args), replace=True)
OmegaConf.register_new_resolver("add", lambda x, y : x + y, replace=True)

def load_config(file_path='./utils/config.yaml'):
    config_data = OmegaConf.load(file_path)
    return config_data

config = load_config()
