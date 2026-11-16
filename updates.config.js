export default {
  exclude: [/^nvidia\/cuda/],
  cooldown: '7d',
  overrides: [{ include: [/^(@camera\.ui\/|camera\.ui$|node-av$|@seydx\/|camera[-_]ui[-_]|github\.com\/(cameraui|seydx)\/)/], cooldown: 0 }],
};
